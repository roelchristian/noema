import AppKit
import Testing
import VaultCore
@testable import noema

/// These tests execute bundled KaTeX in a real WebKit content process and rasterize
/// its vector output. Source-only substitutes cannot satisfy the geometry/ink checks.
@Suite(.serialized) @MainActor
struct MathTypesetterRuntimeTests {
    private func render(_ tex: String, using renderer: MathTypesetter,
                        display: Bool = false, fontSize: CGFloat = 20,
                        color: NSColor = .black, width: CGFloat = 640,
                        macros: [TeXMacro] = []) async -> Result<MathTypesetResult, Error> {
        _ = NSApplication.shared
        return await withCheckedContinuation { continuation in
            renderer.render(tex: tex, display: display, fontSize: fontSize,
                            color: color, width: width, macros: macros) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func bitmap(_ result: MathTypesetResult, background: NSColor? = nil) throws -> NSBitmapImageRep {
        let pixelsWide = Int(ceil(result.size.width * 2))
        let pixelsHigh = Int(ceil(result.size.height * 2))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = result.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        if let background {
            context.cgContext.setFillColor(background.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        }
        result.image.draw(in: NSRect(origin: .zero, size: result.size),
                          from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        return bitmap
    }

    private func capture(_ result: MathTypesetResult, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOEMA_MATH_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(try bitmap(result).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
        let onWhite = try #require(try bitmap(result, background: .white).representation(using: .png, properties: [:]))
        try onWhite.write(to: folder.appendingPathComponent(name + "-on-white.png"))
    }

    @Test func realFractionHasStackedGeometryInkTransparencyAndBaseline() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let slash = try await render("1/2", using: renderer, display: true).get()
        let fraction = try await render(#"\frac{1}{2}"#, using: renderer, display: true).get()
        #expect(fraction.size.height > slash.size.height + 4)
        #expect(fraction.baseline > 2 && fraction.baseline < fraction.size.height - 2)
        try capture(fraction, named: "fraction")
        let pixels = try bitmap(fraction)
        #expect(try #require(pixels.colorAt(x: 0, y: 0)).alphaComponent < 0.01)
        var ink = 0
        var transparent = 0
        for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide {
                let alpha = pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0.1 { ink += 1 }
                if alpha < 0.01 { transparent += 1 }
            }
        }
        #expect(ink > 20)
        #expect(transparent > pixels.pixelsWide * pixels.pixelsHigh / 3)
    }

    @Test func alignedAMSCommandsAndScalableDelimitersRenderLocally() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let single = try await render(#"\operatorname{Hom}_{\mathbb{R}}(G,H)"#,
                                      using: renderer, display: true).get()
        let aligned = try await render(#"\begin{aligned}\operatorname{Hom}_{\mathbb{R}}(G,H)&=\left\{f\mid\frac{f(x)}{2}=x^2\right\}\\\sum_{n=1}^{\infty}\frac{1}{n^2}&=\frac{\pi^2}{6}\end{aligned}"#,
                                       using: renderer, display: true).get()
        #expect(aligned.size.height > single.size.height * 1.5)
        #expect(aligned.size.width > 40 && aligned.size.width <= 640)
        try capture(aligned, named: "aligned-ams")
        let pixels = try bitmap(aligned)
        var upperInk = 0
        var lowerInk = 0
        for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if y < pixels.pixelsHigh / 2 { upperInk += 1 } else { lowerInk += 1 }
            }
        }
        #expect(upperInk > 20 && lowerInk > 20)
    }

    @Test func firstUseFontsPaintEveryGlyphFamily() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        // Each fixture isolates one family: other glyphs cannot conceal a missing
        // font as they can in a formula containing both limits and a large sum.
        let fixtures = [
            ("sum", #"\sum"#),
            ("italic-x", "x"),
            ("blackboard-R", #"\mathbb{R}"#),
            ("calligraphic-A", #"\mathcal{A}"#),
            ("large-left-brace", #"\Biggl\{"#),
            ("large-right-brace", #"\Biggr\}"#)
        ]
        for (name, tex) in fixtures {
            let result = try await render(tex, using: renderer, display: true).get()
            let pixels = try bitmap(result)
            var ink = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    ink += 1
                }
            }
            #expect(ink > 10, "The isolated \(name) glyph must paint on its first use")
            try capture(result, named: "glyph-" + name)
        }
    }

    @Test func macroDefinitionsAndAppearanceParticipateInCacheIdentity() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let short = try #require(TeXMacro(name: "noematest", argCount: 1, body: #"\mathbb{#1}"#))
        let long = try #require(TeXMacro(name: "noematest", argCount: 1, body: #"#1+#1+#1+#1"#))
        let first = try await render(#"\noematest{R}"#, using: renderer, macros: [short]).get()
        let cached = try await render(#"\noematest{R}"#, using: renderer, macros: [short]).get()
        #expect(first.image === cached.image)
        let changed = try await render(#"\noematest{R}"#, using: renderer, macros: [long]).get()
        #expect(changed.size.width > first.size.width * 2)
        let colored = try await render(#"\noematest{R}"#, using: renderer, color: .red, macros: [short]).get()
        #expect(colored.image !== first.image)
        let enlarged = try await render(#"\noematest{R}"#, using: renderer, fontSize: 30, macros: [short]).get()
        #expect(enlarged.size.height > first.size.height)
    }

    @Test func sourceLocalNewcommandOverridesPreferenceWithoutLeaking() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let preference = try #require(TeXMacro(name: "noematest", argCount: 1, body: "Z"))
        let overridden = try await render(#"\newcommand{\noematest}[1]{#1+#1}\noematest{x}"#,
                                         using: renderer, macros: [preference]).get()
        let expectedOverride = try await render("x+x", using: renderer).get()
        #expect(overridden.size == expectedOverride.size)
        let next = try await render(#"\noematest{x}"#, using: renderer, macros: [preference]).get()
        let expectedPreference = try await render("Z", using: renderer).get()
        #expect(next.size == expectedPreference.size)
        #expect(next.size.width < overridden.size.width)
    }

    @Test func malformedAndRecursiveTeXFailWithoutPoisoningNextEquation() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        for tex in [#"\frac{1"#, #"\def\loop{\loop}\loop"#] {
            let outcome = await render(tex, using: renderer)
            if case .success = outcome { Issue.record("Invalid or recursive TeX unexpectedly rendered") }
        }
        let valid = try await render(#"x^2+\frac{1}{y}"#, using: renderer).get()
        #expect(valid.size.width > 10 && valid.size.height > 10)
        #expect(valid.estimatedMemoryCost <= 4 * 1024 * 1024)
    }

    @Test func longEquationsFitMeasureAndOversizedRequestsFail() async throws {
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let fitted = try await render(Array(repeating: #"\frac{1}{x}"#, count: 30).joined(separator: "+"),
                                      using: renderer, display: true, width: 120).get()
        #expect(fitted.size.width <= 120)
        #expect(fitted.size.width > 100)
        #expect(fitted.size.height > 0 && fitted.baseline <= fitted.size.height)
        let huge = await render(#"\rule{50em}{50em}"#, using: renderer, fontSize: 128, width: 4096)
        if case .success = huge { Issue.record("Oversized rendered geometry exceeded its memory budget") }
        let tooLong = await render(String(repeating: "x", count: 32_769), using: renderer)
        if case .success = tooLong { Issue.record("Oversized TeX source was accepted") }
    }

    @Test func cancellationCompletesAllCoalescedCallersAndRendererRestarts() async throws {
        _ = NSApplication.shared
        let renderer = MathTypesetter()
        defer { renderer.removeAllCachedResults() }
        let outcomes: [Bool] = await withCheckedContinuation { continuation in
            var successes: [Bool] = []
            for _ in 0..<2 {
                renderer.render(tex: #"\frac{a}{b}"#, display: false, fontSize: 20,
                                color: .black, width: 640, macros: []) { result in
                    if case .success = result { successes.append(true) } else { successes.append(false) }
                    if successes.count == 2 { continuation.resume(returning: successes) }
                }
            }
            renderer.removeAllCachedResults()
        }
        #expect(outcomes == [false, false])
        let restarted = try await render("x+y", using: renderer).get()
        #expect(restarted.size.width > 10)
    }
}
