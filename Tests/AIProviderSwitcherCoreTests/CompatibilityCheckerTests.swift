import XCTest
@testable import AIProviderSwitcherCore

final class CompatibilityCheckerTests: XCTestCase {
    let endpoint = URL(string: "https://api.deepseek.com/v1/responses")!

    func test200IsCompatible() async throws {
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200), Data()))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-compat-ok-123456"))
        XCTAssertEqual(result.state, .compatible)
    }

    func test401IsIncompatibleAuth() async throws {
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 401), Data()))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-bad-111111111111"))
        if case .incompatible(let reason) = result.state {
            XCTAssertTrue(reason.contains("rejected the key"))
        } else {
            XCTFail("expected incompatible")
        }
    }

    func test404IsIncompatibleResponses() async throws {
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 404), Data()))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-404-111111111111"))
        if case .incompatible(let reason) = result.state {
            XCTAssertTrue(reason.contains("/v1/responses"))
        } else {
            XCTFail("expected incompatible")
        }
    }

    func testConnectionFailureIsIncompatible() async throws {
        struct Boom: Error {}
        let mock = MockHTTPClient(responses: [.failure(Boom())])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-boom-111111111111"))
        if case .incompatible = result.state {
            // ok
        } else {
            XCTFail("expected incompatible on connection failure")
        }
    }

    func testCheckerInjectsBearerNotLogged() async throws {
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200), Data()))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let key = "sk-secret-not-logged-99"
        SecretRegistry.shared.register(Secret(key))
        defer { SecretRegistry.shared.unregisterAll() }
        let sink = MemorySink(); Log.sink = sink; Log.minimumLevel = .debug
        sink.clear()
        _ = try await checker.check(provider: provider, secret: Secret(key))
        XCTAssertFalse(sink.allJoined.contains(key))
        XCTAssertEqual(mock.recorded.first?.hasAuthorization, true)
    }
}
