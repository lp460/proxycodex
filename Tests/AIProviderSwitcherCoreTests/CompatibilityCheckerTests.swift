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

    func test200WithZAI401BodyIsIncompatible() async throws {
        // Z.ai answers HTTP 200 with a flat error object when the key is dead.
        let body = #"{"code":401,"msg":"token expired or incorrect","success":false}"#.data(using: .utf8)!
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200, body: body), body))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "glm"]!
        let result = try await checker.check(provider: provider, secret: Secret("dead.key"))
        if case .incompatible(let reason) = result.state {
            XCTAssertTrue(reason.contains("refusé la clé"))
            XCTAssertTrue(reason.contains("token expired"))
        } else {
            XCTFail("expected incompatible for embedded auth error")
        }
    }

    func test200WithZAI1000AuthFailedBodyIsIncompatible() async throws {
        // Older Z.ai gateways used code 1000 + "Authentication Failed".
        let body = #"{"code":1000,"msg":"Authentication Failed","success":false}"#.data(using: .utf8)!
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200, body: body), body))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "glm"]!
        let result = try await checker.check(provider: provider, secret: Secret("dead.key"))
        if case .incompatible(let reason) = result.state {
            XCTAssertTrue(reason.contains("Authentication Failed"))
        } else {
            XCTFail("expected incompatible for embedded auth error")
        }
    }

    func test200WithErrorCode401ObjectIsIncompatible() async throws {
        let body = #"{"error":{"code":"401","message":"Invalid API key"}}"#.data(using: .utf8)!
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200, body: body), body))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "openrouter"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-dead-111111111111"))
        if case .incompatible(let reason) = result.state {
            XCTAssertTrue(reason.contains("Invalid API key"))
        } else {
            XCTFail("expected incompatible for embedded auth error")
        }
    }

    func test200WithUnrelatedBodyStaysCompatible() async throws {
        // A 200 with a body that is not an auth error (e.g. quota/limit notice)
        // must stay compatible so the probe remains lenient for real successes.
        let body = #"{"code":429,"msg":"rate limit exceeded","success":false}"#.data(using: .utf8)!
        let mock = MockHTTPClient(responses: [.success((MockHTTPClient.makeResponse(url: endpoint, status: 200, body: body), body))])
        let checker = CompatibilityChecker(client: mock)
        let provider = ProviderCatalog.default[id: "deepseek"]!
        let result = try await checker.check(provider: provider, secret: Secret("sk-quota-111111111111"))
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
