import Foundation

public struct WebSourceFetch: Sendable {
    public var data: Data
    public var filename: String
    public init(data: Data, filename: String) { self.data = data; self.filename = filename }
}

public enum WebSourceFetcher {
    public static func lines(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 5 else { throw VaultError.invalid("Enter 1–5 URLs, one per line.") }
        return lines
    }

    public static func validatedURL(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace }), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw VaultError.invalid("Enter a valid http or https URL without spaces or credentials.")
        }
        return url
    }

    /// Wikipedia content is derived from the capture; original response bytes stay intact.
    public static func readableHTML(_ data: Data, from url: URL) throws -> Data {
        let host = (url.host ?? "").lowercased()
        guard host == "wikipedia.org" || host.hasSuffix(".wikipedia.org") else { return data }
        guard let html = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Wikipedia HTML must use UTF-8 encoding.") }
        // Tokenize comments and raw-text elements as units so markup examples cannot
        // masquerade as the article container. Quoted attribute values may contain >.
        let pattern = #"(?is)<!--.*?-->|<script\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?</script\s*>|<style\b(?:[^>"']|"[^"]*"|'[^']*')*>.*?</style\s*>|</?main\b(?:[^>"']|"[^"]*"|'[^']*')*>"#
        let expression = try NSRegularExpression(pattern: pattern)
        let text = html as NSString
        var start: Int?, depth = 0
        for match in expression.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range).lowercased()
            if token.hasPrefix("<main"), !token.hasSuffix("/>") {
                if depth == 0 { start = match.range.location }
                depth += 1
            } else if token.hasPrefix("</main"), depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    return Data(text.substring(with: NSRange(location: start, length: NSMaxRange(match.range) - start)).utf8)
                }
            }
        }
        throw VaultError.unavailable("Wikipedia page has no complete <main> article container.")
    }

    public static func fetch(_ url: URL) async throws -> WebSourceFetch {
        _ = try validatedURL(url.absoluteString)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/html, text/plain, application/pdf", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw VaultError.unavailable("The page could not be fetched (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        guard response.expectedContentLength <= Int64(FileVaultRepository.maximumImportBytes) else {
            throw VaultError.invalid("URL sources must be at most 2 MB.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < FileVaultRepository.maximumImportBytes else { throw VaultError.invalid("URL sources must be at most 2 MB.") }
            data.append(byte)
        }
        guard !data.isEmpty else { throw VaultError.unavailable("The page returned no content.") }
        let ext: String
        switch response.mimeType?.lowercased() {
        case "text/html", "application/xhtml+xml": ext = "html"
        case "text/plain": ext = "txt"
        case "application/pdf": ext = "pdf"
        default: throw VaultError.invalid("This URL must return HTML, plain text, or PDF content.")
        }
        if ext == "html" { _ = try readableHTML(data, from: response.url ?? url) }
        return WebSourceFetch(data: data, filename: "page." + ext)
    }
}
