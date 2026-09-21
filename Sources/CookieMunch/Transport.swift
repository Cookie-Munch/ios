import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injectable network seam so the consent client can be unit-tested without touching the
/// real API. The client only ever calls `post`; a real POST returns void on success and
/// throws on failure — the client swallows any throw so a consent decision is never lost
/// to a flaky network.
public protocol ConsentTransport: Sendable {
    func post(_ url: URL, headers: [String: String], body: Data) async throws
    /// Fetch a resource. Only used to refresh the applicable regulation from
    /// `/config/:cbid`; see the extension below for why it has a default.
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

/// Thrown by the default `get` so a transport written before regulation refresh
/// existed keeps compiling. The client treats any throw here as "stay with the
/// locally-resolved regime", which is exactly the right behaviour for it.
public struct ConsentTransportGetUnsupported: Error {
    public init() {}
}

public extension ConsentTransport {
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        throw ConsentTransportGetUnsupported()
    }
}

/// Default `URLSession`-backed transport.
public struct URLSessionTransport: ConsentTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (name, value) in headers {
            req.setValue(value, forHTTPHeaderField: name)
        }
        _ = try await session.data(for: req)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (name, value) in headers {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let (data, _) = try await session.data(for: req)
        return data
    }
}
