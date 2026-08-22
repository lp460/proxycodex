import XCTest
@testable import AIProviderSwitcherCore

final class BootstrapTests: XCTestCase {
    func testCatalogHasExpectedProviders() {
        let ids = ProviderCatalog.default.providers.map(\.id)
        XCTAssertEqual(ids, ["openai", "deepseek", "glm", "openrouter", "ollama", "opencode", "claude"])
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
        XCTAssertEqual(glm?.baseURL.absoluteString, "https://api.z.ai/api/paas/v4")
        XCTAssertTrue(glm?.models.contains("glm-5.2") ?? false)
    }

    func testDeepSeekResponsesModelPresent() {
        let ds = ProviderCatalog.default[id: "deepseek"]!
        XCTAssertTrue(ds.models.contains("deepseek-v4-flash"))
    }
}
