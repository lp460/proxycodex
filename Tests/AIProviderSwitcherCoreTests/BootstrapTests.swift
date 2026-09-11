import XCTest
@testable import AIProviderSwitcherCore

final class BootstrapTests: XCTestCase {
    func testCatalogHasExpectedProviders() {
        let ids = ProviderCatalog.default.providers.map(\.id)
        XCTAssertEqual(ids, ["openai", "deepseek", "glm", "openrouter", "ollama",
                             "opencode", "opencode-go", "claude"])
    }

    func testOpenRouterExposesFreeModelsFirst() {
        let openrouter = ProviderCatalog.default[id: "openrouter"]!
        XCTAssertEqual(openrouter.defaultModel, "openrouter/free")
        XCTAssertEqual(openrouter.models.first, "openrouter/free")
        XCTAssertTrue(openrouter.models.contains("z-ai/glm-5.2"))
    }

    func testOpenCodeUsesTheZenGatewayWithoutAKey() {
        let opencode = ProviderCatalog.default[id: "opencode"]!
        // The CLI is an agent; the provider talks to the OpenAI-compatible
        // gateway behind it, whose free tier needs no key from the user.
        XCTAssertEqual(opencode.baseURL.absoluteString, "https://opencode.ai/zen/v1")
        XCTAssertTrue(opencode.isKeyless)
        XCTAssertEqual(opencode.environmentVariable, "")
        XCTAssertEqual(opencode.wireAPI, .responses)
        XCTAssertEqual(CodexConfigGenerator.proxyPort(for: "opencode"), 18892)
        XCTAssertTrue(opencode.models.contains("big-pickle"))
    }

    func testOpenCodeGoUsesThePaidGatewayWithAKey() throws {
        let go = try XCTUnwrap(ProviderCatalog.default[id: "opencode-go"])
        XCTAssertEqual(go.displayName, "OpenCode Go")
        XCTAssertEqual(go.baseURL.absoluteString, "https://opencode.ai/zen/go/v1")
        XCTAssertEqual(go.environmentVariable, "OPENCODE_API_KEY")
        XCTAssertFalse(go.isKeyless)
        XCTAssertEqual(go.wireAPI, .responses)
        XCTAssertEqual(CodexConfigGenerator.proxyPort(for: "opencode-go"), 18893)
        XCTAssertEqual(go.defaultModel, "grok-4.6")
        XCTAssertEqual(go.models, ["grok-4.6", "gpt-5.6-luna",
                                   "muse-spark-1.3-contributor",
                                   "muse-spark-1.2-contributor"])
    }

    func testEveryProviderHasModelsAndValidDefault() {
        for provider in ProviderCatalog.default.providers {
            XCTAssertFalse(provider.models.isEmpty, "\(provider.id) has no models")
            XCTAssertTrue(provider.models.contains(provider.defaultModel),
                          "\(provider.id) default \(provider.defaultModel) not in its models \(provider.models)")
        }
    }

    func testGlmProviderConfigured() {
        let glm = ProviderCatalog.default[id: "glm"]
        XCTAssertNotNil(glm)
        XCTAssertEqual(glm?.environmentVariable, "ZAI_API_KEY")
        XCTAssertEqual(glm?.baseURL.absoluteString, "https://api.z.ai/api")
        XCTAssertTrue(glm?.models.contains("glm-5.2") ?? false)
    }

    func testDeepSeekResponsesModelPresent() {
        let ds = ProviderCatalog.default[id: "deepseek"]!
        XCTAssertTrue(ds.models.contains("deepseek-v4-flash"))
    }
}
