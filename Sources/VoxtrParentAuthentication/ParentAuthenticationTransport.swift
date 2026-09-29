import Foundation

/// Where the backend's Parent authentication/redemption Edge Functions
/// live — e.g. `https://<project>.supabase.co/functions/v1` (NO
/// trailing slash; every call below uses
/// `baseURL.appendingPathComponent(...)`). Deliberately just a plain
/// `URL` the composition root supplies, never a literal baked into this
/// package or a secret of any kind — see this package's own README
/// note in `CompositionRoot.swift` for why a local-development default
/// is used until real hosted configuration is approved and supplied.
public struct ParentAuthenticationConfiguration: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

/// Injectable HTTP boundary — production code uses
/// `URLSessionParentAuthenticationTransport`; deterministic tests (no
/// live network, per this task's own requirement to run in Codemagic
/// without a live Apple login or hosted Supabase) inject a fake
/// conforming type instead. Deliberately narrow: one method, taking and
/// returning only plain Foundation types, so a fake needs no real
/// networking stack of its own.
public protocol ParentAuthenticationTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real implementation — a thin `URLSession` wrapper. Never adds a
/// JWKS/issuer override or any other production bypass of any kind;
/// every request this package sends goes to exactly the `baseURL` the
/// composition root configured it with.
public struct URLSessionParentAuthenticationTransport: ParentAuthenticationTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParentAuthenticationError.network
        }
        return (data, httpResponse)
    }
}
