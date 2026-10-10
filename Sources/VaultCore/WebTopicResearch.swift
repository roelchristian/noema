import Foundation

public struct WebTopicResult: Sendable, Equatable {
    public var title: String
    public var url: URL
    public var text: String
}

public enum WebTopicResearch {
    public static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style|nav|footer)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func results(in html: String) -> [WebTopicResult] {
        if html.contains("<rss") {
            guard let itemRegex = try? NSRegularExpression(pattern: "(?is)<item>(.*?)</item>") else { return [] }
            let ns = html as NSString
            var seen: Set<String> = []
            return itemRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { item in
                let content = ns.substring(with: item.range(at: 1)) as NSString
                func field(_ tag: String) -> String? {
                    guard let regex = try? NSRegularExpression(pattern: "(?is)<" + tag + ">(.*?)</" + tag + ">"),
                          let match = regex.firstMatch(in: content as String, range: NSRange(location: 0, length: content.length)) else { return nil }
                    return plainText(content.substring(with: match.range(at: 1)))
                }
                guard let title = field("title"), !title.isEmpty, let address = field("link"),
                      let url = try? WebSourceFetcher.validatedURL(address), seen.insert(url.absoluteString).inserted else { return nil }
                return WebTopicResult(title: title, url: url, text: "")
            }
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b(?=[^>]*\bclass\s*=\s*["'][^"']*\bresult__a\b)[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#) else { return [] }
        let ns = html as NSString
        var seen: Set<String> = []
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var address = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            if address.hasPrefix("//") { address = "https:" + address }
            if let parts = URLComponents(string: address), let target = parts.queryItems?.first(where: { $0.name == "uddg" })?.value { address = target }
            guard let url = try? WebSourceFetcher.validatedURL(address),
                  !(url.host?.hasSuffix("duckduckgo.com") ?? true), seen.insert(url.absoluteString).inserted else { return nil }
            let title = plainText(ns.substring(with: match.range(at: 2)))
            guard !title.isEmpty else { return nil }
            return WebTopicResult(title: title, url: url, text: "")
        }
    }

    public static func fetch(_ url: URL) async throws -> WebSourceFetch {
        if url.host == "www.bing.com", url.path == "/search" { return try await WebSourceFetcher.fetchSearchFeed(url) }
        return try await WebSourceFetcher.fetch(url)
    }

    public static func research(_ topic: String, fetch: @Sendable (URL) async throws -> WebSourceFetch = WebTopicResearch.fetch) async throws -> [WebTopicResult] {
        var search = URLComponents(string: "https://www.bing.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: topic), URLQueryItem(name: "format", value: "rss")]
        let response = try await fetch(search.url!)
        guard let html = String(data: response.data, encoding: .utf8) else { throw VaultError.unavailable("The web search response could not be read.") }
        let ranked = results(in: html)
        guard !ranked.isEmpty else { throw VaultError.unavailable("Web search returned no usable results or was blocked. Try again later.") }
        var articles: [WebTopicResult] = []
        for result in ranked.prefix(5) {
            try Task.checkCancellation()
            do {
                let page = try await fetch(result.url)
                guard page.filename.hasSuffix("html") || page.filename.hasSuffix("txt"), let content = String(data: page.data, encoding: .utf8) else { continue }
                let text = page.filename.hasSuffix("html") ? plainText(content) : content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                articles.append(WebTopicResult(title: result.title, url: result.url, text: String(text.prefix(1800))))
                if articles.count == 3 { break }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        guard !articles.isEmpty else { throw VaultError.unavailable("The search results could not be read. No page was created.") }
        return articles
    }
}
