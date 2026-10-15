import AppKit
import VaultCore
@preconcurrency import WebKit

/// Disposable presentation pixels. Stored TeX remains the editor's content authority.
struct MathTypesetResult {
    let image: NSImage
    let size: NSSize
    /// Distance from the bottom of the image to the text baseline, in points.
    let baseline: CGFloat
    /// Conservative retained cost, including vector bytes and a 2x raster backing.
    let estimatedMemoryCost: Int
}

/// A single offline, nonpersistent WebKit renderer, with bounded work and LRU pixels.
/// No document source or rendered output is written to disk or diagnostic logs.
@MainActor
final class MathTypesetter: NSObject, WKNavigationDelegate {
    static let shared = MathTypesetter()

    private enum RenderError: LocalizedError {
        case unavailable, invalidInput, overloaded, timedOut, cancelled, invalidSize
        var errorDescription: String? {
            switch self {
            case .unavailable: "The local mathematics renderer is unavailable."
            case .invalidInput: "This expression exceeds the local rendering limits."
            case .overloaded: "The mathematics renderer is busy."
            case .timedOut: "Mathematics rendering took too long."
            case .cancelled: "Mathematics rendering was cancelled."
            case .invalidSize: "This expression exceeds the rendering dimensions."
            }
        }
    }

    private struct Key: Hashable {
        let tex: String
        let display: Bool
        let fontSize: CGFloat
        let color: String
        let width: CGFloat
    }
    private typealias Completion = (Result<MathTypesetResult, Error>) -> Void
    private struct Job {
        let id = UUID()
        let key: Key
    }
    private struct Entry {
        let result: MathTypesetResult
        let cost: Int
    }

    private let maximumEntries = 256
    private let maximumBytes = 32 * 1024 * 1024
    private let maximumJobs = 128
    private var entries: [Key: Entry] = [:]
    private var recency: [Key] = []
    private var cacheBytes = 0
    private var callbacks: [Key: [Completion]] = [:]
    private var queue: [Job] = []
    private var current: Job?
    private var timeout: Task<Void, Never>?
    private var webView: WKWebView?
    private var pageURL: URL?
    private var ready = false
    private var generation: UInt64 = 0

    /// Width is the available reading measure; oversized equations scale to fit it.
    /// Callbacks run on the main actor, asynchronously even on cache hits.
    func render(tex: String, display: Bool, fontSize: CGFloat, color: NSColor,
                width: CGFloat, macros: [TeXMacro]? = nil,
                completion: @escaping (Result<MathTypesetResult, Error>) -> Void) {
        guard tex.utf8.count <= 32_768, fontSize.isFinite, width.isFinite,
              fontSize > 0, width > 0 else {
            deliver(completion, .failure(RenderError.invalidInput))
            return
        }
        let rgb = color.usingColorSpace(.sRGB) ?? .labelColor.usingColorSpace(.sRGB) ?? .black
        let css = "rgba(\(rgb.redComponent * 255),\(rgb.greenComponent * 255),\(rgb.blueComponent * 255),\(rgb.alphaComponent))"
        // Let KaTeX perform bounded expansion instead of the legacy Unicode preprocessor.
        // Revalidate decoded preferences, which can bypass TeXMacro's initializer.
        // Source-local declarations retain precedence over saved preferences, as
        // in the legacy presentation path. Parse only names; KaTeX receives the
        // original source unchanged and owns expansion, scope and error handling.
        let localMacroNames = Set(TeXMacro.parseNewcommands(in: tex).macros.map(\.name))
        var definitions = ""
        for stored in macros ?? TeXMacroStore.load() {
            guard let macro = TeXMacro(name: stored.name, argCount: stored.argCount, body: stored.body),
                  !localMacroNames.contains(macro.name) else { continue }
            let parameters = (0..<macro.argCount).map { "#\($0 + 1)" }.joined()
            definitions += "\\def\(macro.command)\(parameters){\(macro.body)}\n"
            guard definitions.utf8.count <= 32_768 else {
                deliver(completion, .failure(RenderError.invalidInput))
                return
            }
        }
        let key = Key(tex: definitions + tex, display: display, fontSize: min(fontSize, 128),
                      color: css, width: min(max(width, 8), 4096))
        if let entry = entries[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            deliver(completion, .success(entry.result))
            return
        }
        if callbacks[key] != nil {
            // Bound duplicate subscribers as well as distinct queued expressions.
            guard callbacks[key]!.count < maximumJobs else {
                deliver(completion, .failure(RenderError.overloaded))
                return
            }
            callbacks[key]!.append(completion)
            return
        }
        guard callbacks.count < maximumJobs else {
            deliver(completion, .failure(RenderError.overloaded))
            return
        }
        callbacks[key] = [completion]
        queue.append(Job(key: key))
        startNext()
    }

    /// Call when leaving/locking a document to discard source-bearing cache keys and work.
    func removeAllCachedResults() {
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        current = nil
        queue.removeAll()
        entries.removeAll()
        recency.removeAll()
        cacheBytes = 0
        ready = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        pageURL = nil
        let pending = callbacks.values.flatMap { $0 }
        callbacks.removeAll()
        for callback in pending { deliver(callback, .failure(RenderError.cancelled)) }
    }

    private func deliver(_ completion: @escaping Completion, _ result: Result<MathTypesetResult, Error>) {
        let scheduledGeneration = generation
        Task { @MainActor in
            completion(scheduledGeneration == self.generation ? result : .failure(RenderError.cancelled))
        }
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.current?.id == job.id else { return }
            self.discardWebView()
            self.finish(job, .failure(RenderError.timedOut))
        }
        if ready { typeset(job) } else if webView == nil { loadRenderer(job) }
    }

    private func loadRenderer(_ job: Job) {
        guard let url = Bundle.module.url(forResource: "render", withExtension: "html", subdirectory: "MathResources") else {
            finish(job, .failure(RenderError.unavailable))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 4096, height: 8192), configuration: configuration)
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        webView = view
        pageURL = url.standardizedFileURL
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func discardWebView() {
        ready = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        pageURL = nil
    }

    private func typeset(_ job: Job) {
        guard let view = webView else { finish(job, .failure(RenderError.unavailable)); return }
        let key = job.key
        view.callAsyncJavaScript(
            "return await window.noemaRenderMath(tex, display, fontSize, color, width);",
            arguments: ["tex": key.tex, "display": key.display, "fontSize": Double(key.fontSize),
                        "color": key.color, "width": Double(key.width)],
            in: nil, in: .page
        ) { [weak self, weak view] response in
            guard let self, let view, self.current?.id == job.id, self.webView === view else { return }
            switch response {
            case .failure(let error): self.finish(job, .failure(error))
            case .success(let value):
                guard let metrics = value as? [String: Any],
                      let width = (metrics["width"] as? NSNumber)?.doubleValue,
                      let height = (metrics["height"] as? NSNumber)?.doubleValue,
                      let baseline = (metrics["baseline"] as? NSNumber)?.doubleValue,
                      width.isFinite, height.isFinite, baseline.isFinite,
                      width > 0, height > 0, width <= 4096, height <= 8192 else {
                    self.finish(job, .failure(RenderError.invalidSize))
                    return
                }
                let rasterCost = Int(ceil(width) * ceil(height) * 16)
                guard rasterCost <= 4 * 1024 * 1024 else {
                    self.finish(job, .failure(RenderError.invalidSize))
                    return
                }
                let size = NSSize(width: width, height: height)
                // WebKit's PDF capture works without an onscreen window and preserves
                // vector glyphs. Transparency is a public API, rather than a KVC override.
                let capture = WKPDFConfiguration()
                capture.rect = NSRect(origin: .zero, size: size)
                capture.allowTransparentBackground = true
                view.createPDF(configuration: capture) { [weak self, weak view] response in
                    guard let self, let view, self.current?.id == job.id, self.webView === view else { return }
                    switch response {
                    case .success(let data):
                        guard data.count + rasterCost <= 4 * 1024 * 1024, let image = NSImage(data: data) else {
                            self.finish(job, .failure(RenderError.unavailable))
                            return
                        }
                        image.size = size
                        let result = MathTypesetResult(image: image, size: size,
                                                       baseline: min(max(0, baseline), height),
                                                       estimatedMemoryCost: data.count + rasterCost)
                        self.cache(result, for: key)
                        self.finish(job, .success(result))
                    case .failure(let error): self.finish(job, .failure(error))
                    }
                }
            }
        }
    }

    private func cache(_ result: MathTypesetResult, for key: Key) {
        let cost = result.estimatedMemoryCost
        guard cost <= maximumBytes else { return }
        while !recency.isEmpty && (entries.count >= maximumEntries || cacheBytes + cost > maximumBytes) {
            let oldest = recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { cacheBytes -= removed.cost }
        }
        entries[key] = Entry(result: result, cost: cost)
        recency.append(key)
        cacheBytes += cost
    }

    private func finish(_ job: Job, _ result: Result<MathTypesetResult, Error>) {
        guard current?.id == job.id else { return }
        timeout?.cancel()
        timeout = nil
        current = nil
        let pending = callbacks.removeValue(forKey: job.key) ?? []
        for callback in pending { deliver(callback, result) }
        startNext()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        ready = true
        if let current { typeset(current) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        rendererFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        rendererFailed(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rendererFailed(webView, error: RenderError.unavailable)
    }

    private func rendererFailed(_ view: WKWebView, error: Error) {
        guard webView === view else { return }
        discardWebView()
        if let current { finish(current, .failure(error)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // CSP independently denies all network subresources, connections and frames.
        let allowed = self.webView === webView && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.standardizedFileURL == pageURL
        return allowed ? .allow : .cancel
    }
}
