import Foundation
import Darwin

/// Source capture accepts public HTTP(S) destinations only, including every redirect.
public enum WebFetchPolicy {
    public static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && (b == 168 || b == 0))
                || (a == 198 && (b == 18 || b == 19 || b == 51)) || (a == 203 && b == 0))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // Accept globally routed unicast only; reject mapped IPv4, loopback, link-local,
        // multicast, unique-local, documentation and transition/tunnel destinations.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        return !(bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] == 0x0d && bytes[3] == 0xb8 || bytes[2] == 0 && bytes[3] == 0))
            && !(bytes[0] == 0x20 && bytes[1] == 0x02)
    }

    public static func validateHost(_ url: URL) throws {
        guard let raw = url.host else { throw VaultError.invalid("A public web address is required.") }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              host.contains(".") || host.contains(":"), url.port == nil || url.port == 80 || url.port == 443 else {
            throw VaultError.invalid("Local and private network addresses are not supported.")
        }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard isPublicAddress(host) else { throw VaultError.invalid("Local and private network addresses are not supported.") }
        }
    }

    public static func validateDestination(_ url: URL) async throws {
        _ = try WebSourceFetcher.validatedURL(url.absoluteString)
        try await Task.detached {
            try Task.checkCancellation()
            guard let raw = url.host else { throw VaultError.invalid("A public web address is required.") }
            let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                throw VaultError.unavailable("The web address could not be resolved.")
            }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let current = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                      isPublicAddress(String(cString: buffer)) else {
                    throw VaultError.invalid("Local and private network addresses are not supported.")
                }
                cursor = current.pointee.ai_next
            }
        }.value
        try Task.checkCancellation()
    }
}

final class WebFetchRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = response.url, let destination = request.url,
              !(original.scheme == "https" && destination.scheme != "https"),
              task.countOfBytesReceived <= FileVaultRepository.maximumImportBytes else { return nil }
        do { try await WebFetchPolicy.validateDestination(destination); return request }
        catch { return nil }
    }
}
