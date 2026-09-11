import XCTest
@testable import AIProviderSwitcherCore

final class CodexConfigGeneratorTests: XCTestCase {

    func testProviderBlockDeepSeek() {
        let toml = CodexConfigGenerator.providerBlock(ProviderCatalog.default[id: "deepseek"]!)
        XCTAssertTrue(toml.contains("[model_providers.deepseek]"))
        XCTAssertTrue(toml.contains("requires_openai_auth = false"))
        XCTAssertTrue(toml.contains("wire_api = \"responses\""))
        // Third-party providers are routed through the local adapter proxy so
        // Codex Desktop can list their models.
        XCTAssertTrue(toml.contains("base_url = \"http://127.0.0.1:18888/v1\""))
        XCTAssertTrue(CodexConfigGenerator.proxyPort(for: "deepseek") == 18888)
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(toml))
        XCTAssertFalse(toml.contains("sk-"))
    }

    /// One credential path for every routed provider: the adapter holds the
    /// key. Declaring `env_key` would give Codex a second, stale source of
    /// truth as soon as the panel changes the key.
    func testRoutedProvidersNeverDeclareEnvKey() {
        for id in ["deepseek", "glm", "openrouter", "opencode", "claude"] {
            let provider = ProviderCatalog.default[id: id]!
            let toml = CodexConfigGenerator.providerBlock(provider)
            XCTAssertFalse(toml.contains("env_key"), id)
            XCTAssertTrue(toml.contains("base_url = \"http://127.0.0.1:"), id)
            XCTAssertTrue(toml.contains("requires_openai_auth = false"), id)
        }
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

        // No models_cache.json here, so masquerading is off: real slug and the
        // portable tool flavor, which is the safe fallback.
        XCTAssertEqual(model["slug"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(model["apply_patch_tool_type"] as? String, "function")
        XCTAssertEqual(model["shell_type"] as? String, "shell_command")
        XCTAssertNil(model["tool_mode"])
        XCTAssertNil(model["web_search_tool_type"])
        XCTAssertEqual(model["supports_parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(model["supports_search_tool"] as? Bool, false)
        XCTAssertTrue((model["experimental_supported_tools"] as? [Any])?.isEmpty == true)
        // Plugins, MCP servers and skills are executed by Codex itself, so their
        // instructions must reach third-party providers too.
        XCTAssertEqual(model["include_plugin_usage_instructions"] as? Bool, true)
        XCTAssertEqual(model["include_apps_usage_instructions"] as? Bool, true)
        XCTAssertEqual(model["include_skills_usage_instructions"] as? Bool, true)
    }

    /// A routed provider must look like one of Codex's own models: the metadata
    /// Codex fetched for that slug is reused as-is, so its full feature contract
    /// applies. Only the two OpenAI-internal wire switches are neutralized.
    /// End-to-end regression for the bug that sent Codex back to its native
    /// catalog: one model carried an extra field and every masqueraded entry
    /// was refused. The catalog must stay masqueraded for the whole provider.
    func testMasqueradeSurvivesAModelWithExtraSchemaFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-hetero-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache: [String: Any] = ["models": [
            ["slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list",
             "supported_in_api": true, "support_verbosity": true,
             "multi_agent_reasoning_effort": "high"],
            ["slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "visibility": "list",
             "supported_in_api": true, "support_verbosity": true]
        ]]
        try JSONSerialization.data(withJSONObject: cache).write(to: url, options: [.atomic])

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "deepseek",
            cacheURL: url
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])

        XCTAssertEqual(models.map { $0["slug"] as? String }, ["gpt-6-astra", "gpt-5.6-sol"])
        // The real model names stay visible to the user, never as slugs.
        XCTAssertTrue(models.allSatisfy {
            ($0["display_name"] as? String)?.contains("DeepSeek") == true
        })
        XCTAssertFalse(models.contains { ($0["slug"] as? String)?.hasPrefix("deepseek-") == true })
    }

    func testMasqueradeCatalogCopiesCodexNativeMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-native-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache: [String: Any] = ["models": [[
            "slug": "gpt-5.6-sol",
            "display_name": "GPT-5.6-Sol",
            "description": "Latest frontier agentic coding model.",
            "visibility": "list",
            "supported_in_api": true,
            "multi_agent_version": "v2",
            "tool_mode": "code_mode_only",
            "use_responses_lite": true,
            "context_window": 272000,
            "model_messages": ["instructions_template": "You are Codex"],
            "supported_reasoning_levels": [["effort": "low", "description": ""],
                                           ["effort": "ultra", "description": ""]]
        ]]]
        try JSONSerialization.data(withJSONObject: cache).write(to: url, options: [.atomic])

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "glm",
            cacheURL: url
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = try XCTUnwrap((object["models"] as? [[String: Any]])?.first)
        let glm = try XCTUnwrap(ProviderCatalog.default[id: "glm"])

        XCTAssertEqual(model["slug"] as? String, "gpt-5.6-sol")
        // Native metadata carried over verbatim.
        XCTAssertEqual(model["multi_agent_version"] as? String, "v2")
        XCTAssertEqual(model["context_window"] as? Int, 272000)
        XCTAssertNotNil(model["model_messages"])
        let efforts = (model["supported_reasoning_levels"] as? [[String: Any]])?
            .compactMap { $0["effort"] as? String }
        XCTAssertEqual(efforts, ["low", "ultra"])   // the adapter clamps the effort
        // Neutralized: an OpenAI-internal wire shape, and a tool mode that would
        // replace the classic tool set (shell, apply_patch, MCP) with code mode.
        XCTAssertEqual(model["use_responses_lite"] as? Bool, false)
        XCTAssertNil(model["tool_mode"])
        // The picker must name the model that actually answers, not the slug it
        // is disguised as: "gpt-5.6-sol · GLM" told the user nothing.
        XCTAssertEqual(model["display_name"] as? String, "\(glm.defaultModel) · GLM (Z.ai)")
        XCTAssertEqual((model["description"] as? String)?.contains(glm.defaultModel), true)
    }

    /// Regression: an entry Codex could not parse made it discard the entire
    /// `config.toml` — providers, MCP servers, sandbox policy, everything. Every
    /// masqueraded entry must therefore carry the full field set of the cache
    /// entry it came from.
    func testMasqueradedEntriesCarryEveryFieldCodexRequires() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-complete-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func entry(_ slug: String, _ visibility: String) -> [String: Any] {
            [
                "slug": slug, "display_name": slug.uppercased(), "description": "",
                "visibility": visibility, "supported_in_api": true,
                "support_verbosity": true, "default_verbosity": "low",
                "default_reasoning_summary": "none", "context_window": 272000,
                "shell_type": "shell_command", "priority": 1
            ]
        }
        try JSONSerialization.data(withJSONObject: ["models": [
            entry("gpt-5.6-sol", "list"), entry("gpt-5.6-terra", "list"), entry("gpt-reserve", "hide")
        ]]).write(to: url, options: [.atomic])

        // claude declares more models than this cache has slugs.
        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers, activeProviderID: "claude", cacheURL: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(json.data(using: .utf8))) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])

        XCTAssertEqual(models.count, 3, "no slug may be invented to pad the list")
        for model in models {
            for field in ["support_verbosity", "default_verbosity", "default_reasoning_summary",
                          "context_window", "shell_type", "visibility", "supported_in_api"] {
                XCTAssertNotNil(model[field], "\(model["slug"] ?? "?") lacks \(field)")
            }
        }
    }

    func testIncompleteCatalogIsRefusedBeforeItReachesCodex() {
        let native = ["gpt-5.6-sol": ["slug": "gpt-5.6-sol", "support_verbosity": true,
                                      "visibility": "list"] as [String: Any]]
        XCTAssertTrue(CodexConfigGenerator.catalogIsComplete(
            [["slug": "gpt-5.6-sol", "support_verbosity": true, "visibility": "list"]],
            comparedTo: native))
        XCTAssertFalse(CodexConfigGenerator.catalogIsComplete(
            [["slug": "gpt-5.6-sol", "visibility": "list"]], comparedTo: native))
        // Fields Codex treats as optional may legitimately be absent.
        XCTAssertTrue(CodexConfigGenerator.catalogIsComplete(
            [["slug": "gpt-5.6-sol", "support_verbosity": true, "visibility": "list"]],
            comparedTo: ["gpt-5.6-sol": native["gpt-5.6-sol"]!
                .merging(["tool_mode": "code_mode_only"]) { $1 }]))
    }

    /// Regression: Codex evolved its schema per model (`gpt-6-astra` carries
    /// `multi_agent_reasoning_effort`, older slugs do not). Comparing every entry
    /// to the union of all fields made each entry look incomplete, silently
    /// disabled masquerading, and Codex fell back to its native catalog.
    func testCatalogCompletenessIsPerModelNotUnionOfFields() {
        let native: [String: [String: Any]] = [
            "gpt-6-astra": ["slug": "gpt-6-astra", "support_verbosity": true,
                            "multi_agent_reasoning_effort": "high"],
            "gpt-5.6-sol": ["slug": "gpt-5.6-sol", "support_verbosity": true]
        ]
        XCTAssertTrue(CodexConfigGenerator.catalogIsComplete(
            [["slug": "gpt-5.6-sol", "support_verbosity": true],
             ["slug": "gpt-6-astra", "support_verbosity": true,
              "multi_agent_reasoning_effort": "high"]],
            comparedTo: native))
        // A field missing from the entry's own source still refuses the batch.
        XCTAssertFalse(CodexConfigGenerator.catalogIsComplete(
            [["slug": "gpt-5.6-sol"]], comparedTo: native))
        // An entry with no source at all cannot be trusted either.
        XCTAssertFalse(CodexConfigGenerator.catalogIsComplete(
            [["slug": "invented", "support_verbosity": true]], comparedTo: native))
    }

    /// Ollama is a Codex built-in with no adapter to rewrite the model name, so
    /// it keeps its real slugs and the portable tool flavor.
    func testOllamaKeepsRealSlugsAndPortableCapabilities() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-ollama-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache: [String: Any] = ["models": [[
            "slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "description": "",
            "visibility": "list", "supported_in_api": true, "multi_agent_version": "v2",
            "supported_reasoning_levels": [["effort": "ultra", "description": ""]]
        ]]]
        try JSONSerialization.data(withJSONObject: cache).write(to: url, options: [.atomic])

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "ollama",
            cacheURL: url
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let ollama = try XCTUnwrap(ProviderCatalog.default[id: "ollama"])

        XCTAssertEqual(models.map { $0["slug"] as? String }, ollama.models)
        XCTAssertEqual(models.first?["apply_patch_tool_type"] as? String, "function")
        XCTAssertNil(models.first?["multi_agent_version"])
        let efforts = (models.first?["supported_reasoning_levels"] as? [[String: Any]])?
            .compactMap { $0["effort"] as? String }
        XCTAssertEqual(efforts, ["low", "medium", "high"])
    }

    func testEveryProviderGetsTheFullToolSetInAPortableFlavor() {
        let openAI = ProviderCatalog.default[id: "openai"]!
        XCTAssertTrue(openAI.supportsTools)
        XCTAssertTrue(openAI.supportsApplyPatch)
        XCTAssertTrue(openAI.supportsParallelToolCalls)
        // Only OpenAI speaks Codex's native freeform/custom tool wire format.
        XCTAssertTrue(openAI.supportsCustomTools)

        for provider in ProviderCatalog.default.providers where provider.id != "openai" {
            // Same agentic feature set everywhere: shell, apply_patch, plan
            // updates and MCP tools, bridged to function tools by the adapter.
            XCTAssertTrue(provider.supportsTools, provider.id)
            XCTAssertTrue(provider.supportsApplyPatch, provider.id)
            XCTAssertFalse(provider.supportsCustomTools, provider.id)
        }
    }

    func testCatalogOmitsNullValuesFromCacheTemplate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-null-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache: [String: Any] = [
            "models": [[
                "slug": "cached",
                "display_name": "Cached",
                "description": "",
                "visibility": "list",
                "supported_in_api": true,
                "upgrade": NSNull(),
                "web_search_tool_type": NSNull(),
                "nested": ["optional": NSNull()]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: url, options: [.atomic])

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "deepseek",
            cacheURL: url
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = try XCTUnwrap((object["models"] as? [[String: Any]])?.first)

        XCTAssertNil(model["upgrade"])
        XCTAssertNil(model["web_search_tool_type"])
        XCTAssertNil((model["nested"] as? [String: Any])?["optional"])
        XCTAssertFalse(json.contains(": null"))
    }

    func testClaudeCatalogIsExposedUnderCodexNativeSlugs() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-claude-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Masquerading mirrors the slugs Codex fetched, so a cache is required.
        try JSONSerialization.data(withJSONObject: ["models": [
            ["slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "visibility": "list",
             "supported_in_api": true, "support_verbosity": true],
            ["slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list",
             "supported_in_api": true, "support_verbosity": true],
            ["slug": "codex-auto-review", "display_name": "Codex Auto Review",
             "visibility": "hide", "supported_in_api": true, "support_verbosity": true]
        ]]).write(to: url, options: [.atomic])

        let json = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "claude",
            cacheURL: url
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let claude = try XCTUnwrap(ProviderCatalog.default[id: "claude"])
        let aliases = ModelMasquerade.aliases(for: claude, cacheURL: url)

        XCTAssertEqual(models.map { $0["slug"] as? String }, aliases.map { $0.slug })
        // No Claude model name is exposed to Codex as a slug…
        XCTAssertFalse(models.contains { ($0["slug"] as? String)?.hasPrefix("claude-") == true })
        // …but every entry says which one really answers, and only Claude models.
        XCTAssertTrue(models.allSatisfy { entry in
            claude.models.contains { (entry["description"] as? String)?.contains($0) == true }
        })
        XCTAssertTrue(models.allSatisfy {
            ($0["display_name"] as? String)?.hasSuffix(" · Claude Code") == true
        })
        // Slugs Codex uses internally stay hidden from the picker.
        XCTAssertEqual(models.filter { ($0["visibility"] as? String) == "hide" }.count,
                       aliases.filter { !$0.listed }.count)
    }

    func testGeneratedCatalogDetectionRecognizesPreMasqueradeCatalogs() throws {
        let claude = try XCTUnwrap(ProviderCatalog.default[id: "claude"])
        let legacyEntries: [[String: Any]] = claude.models.map { model in
            [
                "slug": model,
                "display_name": "\(claude.displayName) · \(model)",
                "description": "\(claude.displayName) model \(model).",
                "visibility": "list",
                "supported_in_api": true
            ]
        }
        let generated = try JSONSerialization.data(withJSONObject: ["models": legacyEntries])
        XCTAssertTrue(CodexConfigGenerator.isGeneratedCatalog(
            generated,
            providers: ProviderCatalog.default.providers
        ))

        let custom = """
        {"models":[{"slug":"custom","display_name":"Custom · custom","description":"Custom model custom.","visibility":"list","supported_in_api":true}]}
        """
        XCTAssertFalse(CodexConfigGenerator.isGeneratedCatalog(
            try XCTUnwrap(custom.data(using: .utf8)),
            providers: ProviderCatalog.default.providers
        ))
    }

    func testContainsKeyLikeFieldDetectsSecrets() {
        XCTAssertTrue(CodexConfigGenerator.containsKeyLikeField("api_key = \"sk-xxx\""))
        XCTAssertTrue(CodexConfigGenerator.containsKeyLikeField("Authorization: Bearer sk-xxx"))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField("env_key = \"DEEPSEEK_API_KEY\""))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField("model = \"deepseek-v4-flash\""))
    }
}
