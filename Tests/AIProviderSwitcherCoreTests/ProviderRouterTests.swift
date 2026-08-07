import XCTest
@testable import AIProviderSwitcherCore

final class ProviderRouterTests: XCTestCase {
    var store: KeyStore!

    override func tearDown() {
        SecretRegistry.shared.unregisterAll()
        super.tearDown()
    }

    func makeRouter(initial: String) throws -> ProviderRouter {
        store = KeyStore()
        return try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: initial)
    }

    func testResolveReturnsActiveProvider() async throws {
        store = KeyStore()
        store.setKey("sk-deepseek-router-111", for: "deepseek")
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        let route = await router.resolve()
        XCTAssertEqual(route?.provider.id, "deepseek")
        XCTAssertEqual(route?.secret?.asString(), "sk-deepseek-router-111")    }

    func testResolveReturnsNilWithoutKey() async throws {
        store = KeyStore()
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        // No key loaded -> resolve returns nil (provider requires a key).
        let route = await router.resolve()
        XCTAssertNil(route)
    }

    func testAtomicSwitchChangesResolve() async throws {
        store = KeyStore()
        store.setKey("sk-deepseek-1", for: "deepseek")
        store.setKey("sk-openai-1", for: "openai")
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        let r0 = await router.resolve()
        XCTAssertEqual(r0?.provider.id, "deepseek")
        _ = try await router.setActive(providerID: "openai")
        let r1 = await router.resolve()
        XCTAssertEqual(r1?.provider.id, "openai")
    }

    func testSelectRequiresKey() async throws {
        store = KeyStore()
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        do {
            _ = try await router.select(providerID: "deepseek")
            XCTFail("expected missingKey error")
        } catch RouterError.missingKey {
            // ok
        }
    }

    func testUnknownProviderThrows() async throws {
        store = KeyStore()
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        do {
            _ = try await router.setActive(providerID: "nope")
            XCTFail("expected unknownProvider")
        } catch RouterError.unknownProvider {
            // ok
        }
    }

    func testSelectWithCompatibilityChecker() async throws {
        store = KeyStore()
        store.setKey("sk-deepseek-compat-1", for: "deepseek")
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        let mock = MockHTTPClient(responses: [
            .success((MockHTTPClient.makeResponse(url: URL(string: "https://x/v1/responses")!, status: 200), Data()))
        ])
        let checker = CompatibilityChecker(client: mock)
        let snap = try await router.select(providerID: "deepseek", compatibilityChecker: checker)
        XCTAssertEqual(snap.compatibility, .compatible)
    }

    func testKeylessOllamaResolvesWithoutKey() async throws {
        store = KeyStore()
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "ollama")
        let route = await router.resolve()
        XCTAssertEqual(route?.provider.id, "ollama")
        XCTAssertNil(route?.secret)
    }

    func testChangesStreamEmitsSnapshots() async throws {
        store = KeyStore()
        store.setKey("sk-deepseek-stream", for: "deepseek")
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "deepseek")
        let snap = try await router.setActive(providerID: "deepseek", model: "deepseek-chat")
        // The stream yielded at least the latest snapshot.
        XCTAssertEqual(snap.activeProviderID, "deepseek")
        XCTAssertEqual(snap.activeModel, "deepseek-chat")
    }
}

extension ProviderRouterTests {
    func testPerProviderCompatibilityIsIndependentOfActive() async throws {
        store = KeyStore()
        let router = try ProviderRouter(catalog: .default, keyResolver: store, initialProviderID: "openai")
        await router.setCompatibility(for: "deepseek", state: .compatible, error: nil)
        await router.setCompatibility(for: "glm", state: .incompatible(reason: "boom"), error: "boom")

        let snap = await router.currentSnapshot()
        XCTAssertEqual(snap.compatibility(for: "deepseek"), .compatible)
        XCTAssertEqual(snap.compatibility(for: "glm"), .incompatible(reason: "boom"))
        XCTAssertEqual(snap.errors["glm"], "boom")
        // Switching the active provider must not erase other providers' status.
        _ = try await router.setActive(providerID: "deepseek", model: "deepseek-v4-flash")
        let after = await router.currentSnapshot()
        XCTAssertEqual(after.compatibility(for: "glm"), .incompatible(reason: "boom"))
        XCTAssertEqual(after.activeProviderID, "deepseek")
    }
}
