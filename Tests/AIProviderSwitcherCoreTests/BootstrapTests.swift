import XCTest
@testable import AIProviderSwitcherCore

final class BootstrapTests: XCTestCase {
    func testCatalogHasExpectedProviders() {
        let ids = ProviderCatalog.default.providers.map(\.id)
        XCTAssertEqual(ids, ["openai", "deepseek", "glm", "openrouter", "ollama", "claude"])
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
