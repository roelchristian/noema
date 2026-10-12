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
