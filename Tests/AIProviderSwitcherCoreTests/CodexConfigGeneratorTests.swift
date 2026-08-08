import XCTest
@testable import AIProviderSwitcherCore

final class CodexConfigGeneratorTests: XCTestCase {

    func testProviderBlockDeepSeek() {
        let toml = CodexConfigGenerator.providerBlock(ProviderCatalog.default[id: "deepseek"]!)
        XCTAssertTrue(toml.contains("[model_providers.deepseek]"))
        XCTAssertTrue(toml.contains("env_key = \"DEEPSEEK_API_KEY\""))
        XCTAssertTrue(toml.contains("requires_openai_auth = false"))
        XCTAssertTrue(toml.contains("wire_api = \"responses\""))
        // Third-party providers are routed through the local adapter proxy so
        // Codex Desktop can list their models.
        XCTAssertTrue(toml.contains("base_url = \"http://127.0.0.1:18888/v1\""))
        XCTAssertTrue(CodexConfigGenerator.proxyPort(for: "deepseek") == 18888)
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(toml))
        XCTAssertFalse(toml.contains("sk-"))
    }

    func testReservedIDsIncludeBuiltins() {
        for id in ["openai", "ollama", "lmstudio"] {
            XCTAssertTrue(CodexConfigGenerator.reservedProviderIDs.contains(id))
        }
        XCTAssertTrue(ProviderCatalog.default[id: "ollama"]?.isReserved ?? false)
        XCTAssertFalse(ProviderCatalog.default[id: "deepseek"]?.isReserved ?? true)
    }

    func testProfileFileHasKeyFreeOverride() {
        let toml = CodexConfigGenerator.profileFile(model: "deepseek-v4-flash", providerID: "deepseek")
        XCTAssertTrue(toml.contains("model = \"deepseek-v4-flash\""))
        XCTAssertTrue(toml.contains("model_provider = \"deepseek\""))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(toml))
    }

    func testCatalogAdvertisesCodexToolCapabilities() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-model-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "deepseek",
            cacheURL: url
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = try XCTUnwrap((object["models"] as? [[String: Any]])?.first)

        XCTAssertEqual(model["apply_patch_tool_type"] as? String, "freeform")
        XCTAssertTrue(model["web_search_tool_type"] is NSNull)
        XCTAssertEqual(model["supports_parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(model["supports_search_tool"] as? Bool, false)
        XCTAssertEqual(model["tool_mode"] as? String, "code_mode_only")
        XCTAssertTrue((model["experimental_supported_tools"] as? [Any])?.isEmpty == true)
    }

    func testContainsKeyLikeFieldDetectsSecrets() {
        XCTAssertTrue(CodexConfigGenerator.containsKeyLikeField("api_key = \"sk-xxx\""))
        XCTAssertTrue(CodexConfigGenerator.containsKeyLikeField("Authorization: Bearer sk-xxx"))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField("env_key = \"DEEPSEEK_API_KEY\""))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField("model = \"deepseek-v4-flash\""))
    }
}
