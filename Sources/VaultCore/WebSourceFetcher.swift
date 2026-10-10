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

    public static func fetch(_ url: URL) async throws -> WebSourceFetch {
        try await fetch(url, allowXML: false)
    }

    public static func fetchSearchFeed(_ url: URL) async throws -> WebSourceFetch {
        try await fetch(url, allowXML: true)
    }

    private static func fetch(_ url: URL, allowXML: Bool) async throws -> WebSourceFetch {
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
        case "text/xml", "application/xml", "application/rss+xml":
            guard allowXML else { throw VaultError.invalid("This URL must return HTML, plain text, or PDF content.") }
            ext = "txt"
        default: throw VaultError.invalid("This URL must return HTML, plain text, or PDF content.")
        }
        return WebSourceFetch(data: data, filename: "page." + ext)
    }
}
