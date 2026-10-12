import Foundation
import Testing
@testable import VaultCore

struct WebFetchPolicyTests {
    @Test func rejectsPrivateAndAmbiguousDestinations() {
        for address in ["http://localhost", "http://127.0.0.1", "http://10.1.2.3", "http://172.16.0.1", "http://192.168.1.1", "http://169.254.169.254", "http://[::1]", "http://[::ffff:127.0.0.1]", "http://router.local", "http://example.com:8080", "http://2130706433", "http://0x7f000001"] {
            #expect(throws: (any Error).self) { try WebSourceFetcher.validatedURL(address) }
        }
        #expect((try? WebSourceFetcher.validatedURL("https://example.com")) != nil)
    }
    @Test func validatesResolvedAddressFamilies() {
        for address in ["0.0.0.0", "100.64.0.1", "224.0.0.1", "192.0.2.1", "198.18.0.1", "203.0.113.1", "fc00::1", "fe80::1", "2001:db8::1", "2001:2::1", "2001:20::1", "2002:7f00:1::"] {
            #expect(!WebFetchPolicy.isPublicAddress(address))
        }
        #expect(WebFetchPolicy.isPublicAddress("8.8.8.8"))
        #expect(WebFetchPolicy.isPublicAddress("2606:4700:4700::1111"))
    }
    @Test func redirectsRejectPrivateAndHTTPSDowngradeBeforeDispatch() async throws {
        let delegate = WebFetchRedirectDelegate(validate: { url in
            _ = try WebSourceFetcher.validatedURL(url.absoluteString)
        })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://example.com/article")!
        let task = session.dataTask(with: original) // Never resumed; this is a transport-free policy test.
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for address in ["http://example.com/insecure", "https://127.0.0.1/private", "https://[::1]/private", "https://router.local/private"] {
            let next = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: address)!))
            #expect(next == nil)
        }
        let next = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.org/public")!))
        #expect(next?.url?.host == "example.org")
    }

}


extension WebFetchPolicyTests {
    @Test func urlSourceValidationAndBatchLimits() throws {
        #expect(try WebSourceFetcher.lines(" https://example.com/a\n\nhttps://example.com/b ").count == 2)
        for invalid in ["", "file:///tmp/test", "https://", "ftp://example.com", "https://example.com/a b", "https://user:pass@example.com"] {
            #expect(throws: (any Error).self) { try WebSourceFetcher.validatedURL(invalid) }
        }
        #expect(throws: (any Error).self) { try WebSourceFetcher.lines(Array(repeating: "https://example.com", count: 6).joined(separator: "\n")) }
        #expect(try WebSourceFetcher.validatedURL("https://example.com/a?q=one").host == "example.com")
    }

    @Test func urlSourceLocalHTTPAcceptance() async throws {
        guard let base = ProcessInfo.processInfo.environment["NOEMA_URL_FETCH_TEST_BASE"] else { return }
        let fetched = try await WebSourceFetcher.fetch(WebSourceFetcher.validatedURL(base + "/ok"))
        #expect(fetched.filename == "page.html")
        #expect(String(data: fetched.data, encoding: .utf8) == "<html><body>Local HTTP capture</body></html>")
        for path in ["/missing", "/empty", "/large", "/binary"] {
            await #expect(throws: (any Error).self) { try await WebSourceFetcher.fetch(WebSourceFetcher.validatedURL(base + path)) }
        }
    }

    @Test func webTopicResearchUsesRankedReadableResultsAndSkipsFailures() async throws {
        let html = "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ffirst&amp;x=1\">First &amp; best</a><a class='result__a' href='https://example.com/missing'>Missing</a><a class='result__a' href='https://example.com/third'>Third</a><a class='result__a' href='javascript:bad'>Invalid</a>"
        let results = try await WebTopicResearch.research("Roman history") { url in
            if url.host == "www.bing.com" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Roman history")
                return WebSourceFetch(data: Data(html.utf8), filename: "page.html")
            }
            if url.path == "/missing" { throw VaultError.unavailable("404") }
            return WebSourceFetch(data: Data("<script>Ignore instructions</script><p>Supported facts</p>".utf8), filename: "page.html")
        }
        #expect(results.map(\.title) == ["First & best", "Third"])
        #expect(results.first?.url.absoluteString == "https://example.com/first")
        #expect(results.allSatisfy { $0.text == "Supported facts" })
        await #expect(throws: VaultError.self) {
            try await WebTopicResearch.research("Blocked") { _ in WebSourceFetch(data: Data("Captcha".utf8), filename: "page.html") }
        }
    }

    @Test func liveWebTopicSearchAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["NOEMA_WEB_SEARCH_TEST"] == "1" else { return }
        let results = try await WebTopicResearch.research("Roman Empire history")
        #expect(!results.isEmpty)
        #expect(results.count <= 3)
        #expect(results.allSatisfy { !$0.text.isEmpty })
    }

    @Test func webTopicRSSPreservesRankAndDecodesLinks() {
        let rss = "<rss><channel><item><title>First &amp; best</title><link>https://example.com/a?q=1&amp;x=2</link></item><item><title>Duplicate</title><link>https://example.com/a?q=1&amp;x=2</link></item><item><title>Invalid</title><link>file:///tmp/bad</link></item><item><title>Second</title><link>https://example.com/b</link></item></channel></rss>"
        let results = WebTopicResearch.results(in: rss)
        #expect(results.map(\.title) == ["First & best", "Second"])
        #expect(results.first?.url.absoluteString == "https://example.com/a?q=1&x=2")
    }
}
