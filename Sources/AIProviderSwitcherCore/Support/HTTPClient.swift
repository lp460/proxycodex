import Foundation
import os

/// Minimal HTTP client abstraction so networking-dependent code can be tested
/// with a mock instead of hitting real providers.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http, data)
    }
}

/// A scripted mock client used in tests. Returns canned responses in order, and
/// records the requests it received (without ever persisting Authorization).
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public struct RecordedRequest: Sendable, Equatable {
        public let url: URL
        public let method: String
        public let hasAuthorization: Bool
        public let body: Data?
    }
    private struct State {
        var responses: [Result<(HTTPURLResponse, Data), Error>] = []
        var recorded: [RecordedRequest] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(responses: [Result<(HTTPURLResponse, Data), Error>]) {
        state.withLock { $0.responses = responses }
    }

    public func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let next: Result<(HTTPURLResponse, Data), Error> = state.withLock { (s: inout State) -> Result<(HTTPURLResponse, Data), Error> in
            s.recorded.append(RecordedRequest(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                hasAuthorization: (request.value(forHTTPHeaderField: "Authorization") != nil),
                body: request.httpBody
            ))
            if s.responses.isEmpty {
                return .success((Self.makeResponse(url: request.url!, status: 599), Data()))
            }
            return s.responses.removeFirst()
        }
        return try next.get()
    }

    public var recorded: [RecordedRequest] {
        state.withLock { $0.recorded }
    }

    public static func makeResponse(url: URL, status: Int, body: Data = Data(), headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
