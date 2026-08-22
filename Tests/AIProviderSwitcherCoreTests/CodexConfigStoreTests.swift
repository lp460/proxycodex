import XCTest
@testable import AIProviderSwitcherCore

final class CodexConfigStoreTests: XCTestCase {
    var home: URL!
    var paths: CodexPaths!
    var store: CodexConfigStore!

    let nativeConfig = """
    # My native Codex/OpenAI config — do not touch
    model = "gpt-5.6"
    model_provider = "openai"

    [mcp_servers.github]
    command = "npx"
    args = ["-y", "@modelcontextprotocol/server-github"]
    """

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("aps-\(UUID().uuidString)")
        paths = CodexPaths(
            codexHome: home,
            configToml: home.appendingPathComponent("config.toml"),
            stateJson: home.appendingPathComponent("state.json"),
            backupDir: home.appendingPathComponent("backups"),
            catalogJson: home.appendingPathComponent("catalog.json"),
            modelsCacheJson: home.appendingPathComponent("models_cache.json")
        )
        store = CodexConfigStore(paths: paths)
        try? writeModelsCache()
    }

    /// Production-like state: Codex has fetched its model catalog, so providers
    /// masquerade under its slugs. Without this file masquerading stays off.
    private func writeModelsCache() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let entry: ([String: Any]) -> [String: Any] = { extra in
            var base: [String: Any] = ["display_name": "Native", "description": "",
                                       "supported_in_api": true, "support_verbosity": true,
                                       "default_verbosity": "low", "shell_type": "shell_command"]
            base.merge(extra) { _, new in new }
            return base
        }
        try JSONSerialization.data(withJSONObject: ["models": [
            entry(["slug": "gpt-5.6-sol", "visibility": "list"]),
            entry(["slug": "gpt-5.6-terra", "visibility": "list"]),
            entry(["slug": "gpt-5.6-luna", "visibility": "list"]),
            entry(["slug": "gpt-5.5", "visibility": "list"]),
            entry(["slug": "gpt-5.4", "visibility": "list"]),
            entry(["slug": "codex-auto-review", "visibility": "hide"])
        ]]).write(to: paths.modelsCacheJson, options: [.atomic])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func writeNative() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try nativeConfig.write(to: paths.configToml, atomically: true, encoding: .utf8)
    }

    // MARK: Install (additive)

    func testInstallAppendsProvidersAndPreservesNative() throws {
        try writeNative()
        let report = try store.install(providers: ProviderCatalog.default.providers)
        let config = try store.readConfig()

        XCTAssertTrue(report.providersAdded.contains("deepseek"))
        XCTAssertTrue(report.providersAdded.contains("glm"))
        XCTAssertTrue(report.providersAdded.contains("openrouter"))
        // Reserved built-ins are NEVER declared.
        XCTAssertFalse(report.providersAdded.contains("openai"))
        XCTAssertFalse(report.providersAdded.contains("ollama"))
        XCTAssertFalse(config.contains("[model_providers.openai]"))
        XCTAssertFalse(config.contains("[model_providers.ollama]"))
        XCTAssertTrue(config.contains("[model_providers.deepseek]"))
        XCTAssertTrue(config.contains("[model_providers.glm]"))

        // Native content preserved.
        XCTAssertTrue(config.contains("[mcp_servers.github]"))
        XCTAssertTrue(config.contains("# My native Codex/OpenAI config"))
        XCTAssertTrue(config.contains("web_search = true"))
        XCTAssertTrue(config.contains("# >>> provider-switcher tools >>>"))

        // No key anywhere.
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(config))

        // Profile files written (openai skipped).
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("deepseek.config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("openai.config.toml").path))
        XCTAssertNotNil(report.backupWritten)
    }

    /// A user-owned `[tools] web_search` must win: a second assignment in the
    /// same table makes Codex reject config.toml, which would take MCP servers
    /// and every other user section down with it.
    func testExistingWebSearchValueIsNeverDuplicated() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        model = "gpt-5.6"

        [tools]
        web_search = false

        [mcp_servers.github]
        command = "npx"
        """.write(to: paths.configToml, atomically: true, encoding: .utf8)

        try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "claude")
        let config = try store.readConfig()

        XCTAssertEqual(config.components(separatedBy: "web_search").count - 1, 1)
        XCTAssertTrue(config.contains("web_search = false"))
        XCTAssertFalse(config.contains("# >>> provider-switcher tools >>>"))
        XCTAssertTrue(config.contains("[mcp_servers.github]"))
    }

    /// Codex reloads its whole configuration — and drops its websocket — on every
    /// change of config.toml. A rewrite with identical content is a visible
    /// reconnection for the user, so it must not happen.
    func testUnchangedConfigIsNotRewritten() throws {
        try writeNative()
        _ = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "deepseek")
        let firstWrite = try FileManager.default
            .attributesOfItem(atPath: paths.configToml.path)[.modificationDate] as? Date
        let backupsAfterFirst = (try? FileManager.default
            .contentsOfDirectory(atPath: paths.backupDir.path).count) ?? 0

        // Same call again: nothing to change.
        let report = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "deepseek")
        let secondWrite = try FileManager.default
            .attributesOfItem(atPath: paths.configToml.path)[.modificationDate] as? Date
        let backupsAfterSecond = (try? FileManager.default
            .contentsOfDirectory(atPath: paths.backupDir.path).count) ?? 0

        XCTAssertEqual(firstWrite, secondWrite, "config.toml was rewritten with identical content")
        XCTAssertEqual(backupsAfterFirst, backupsAfterSecond, "a no-op write still made a backup")
        XCTAssertNil(report.backupWritten)
    }

    /// When Codex itself wrote the selection we would have written (the user
    /// changed model in the Desktop picker), only the sidecar needs updating.
    func testRecordSelectionUpdatesTheSidecarWithoutTouchingConfig() throws {
        try writeNative()
        let deepseek = try XCTUnwrap(ProviderCatalog.default[id: "deepseek"])
        _ = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "deepseek")
        _ = try store.applyOverride(provider: deepseek, model: deepseek.defaultModel)
        let exposed = try XCTUnwrap(store.overrideState()?.exposedModel)
        let before = try FileManager.default
            .attributesOfItem(atPath: paths.configToml.path)[.modificationDate] as? Date

        XCTAssertTrue(store.selectionMatchesConfig(provider: deepseek, exposedModel: exposed))
        let other = try XCTUnwrap(deepseek.models.first { $0 != deepseek.defaultModel })
        let state = try store.recordSelection(provider: deepseek, model: other, exposedModel: exposed)

        XCTAssertEqual(state.model, other)
        XCTAssertEqual(store.overrideState()?.model, other)
        // Native values must survive, so "OpenAI" still restores them.
        XCTAssertEqual(state.nativeModel, "gpt-5.6")
        XCTAssertEqual(state.nativeModelProvider, "openai")
        let after = try FileManager.default
            .attributesOfItem(atPath: paths.configToml.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "config.toml must not be touched")
    }

    func testSelectionMatchesConfigRejectsADifferentSelection() throws {
        try writeNative()
        let deepseek = try XCTUnwrap(ProviderCatalog.default[id: "deepseek"])
        let glm = try XCTUnwrap(ProviderCatalog.default[id: "glm"])
        _ = try store.applyOverride(provider: deepseek, model: deepseek.defaultModel)
        let exposed = try XCTUnwrap(store.overrideState()?.exposedModel)

        XCTAssertFalse(store.selectionMatchesConfig(provider: glm, exposedModel: exposed))
        XCTAssertFalse(store.selectionMatchesConfig(provider: deepseek, exposedModel: "gpt-9-other"))
    }

    func testSwitchingFromLegacyGeneratedCatalogRefreshesActiveProvider() throws {
        try writeNative()
        let openAI = try XCTUnwrap(ProviderCatalog.default[id: "openai"])
        let legacyEntries: [[String: Any]] = openAI.models.map { model in
            [
                "slug": model,
                "display_name": "OpenAI · \(model)",
                "description": "OpenAI model \(model).",
                "visibility": "list",
                "supported_in_api": true
            ]
        }
        let legacyData = try JSONSerialization.data(withJSONObject: ["models": legacyEntries])
        try legacyData.write(to: paths.catalogJson, options: [.atomic])
        var config = try store.readConfig()
        config = config.replacingOccurrences(
            of: "model_provider = \"openai\"\n",
            with: "model_provider = \"openai\"\nmodel_catalog_json = \"\(paths.catalogJson.path)\"\n"
        )
        try config.write(to: paths.configToml, atomically: true, encoding: .utf8)

        _ = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "claude")

        let catalogData = try Data(contentsOf: paths.catalogJson)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        let claude = try XCTUnwrap(ProviderCatalog.default[id: "claude"])
        XCTAssertEqual(models.map { $0["slug"] as? String },
                       ModelMasquerade.aliases(for: claude, cacheURL: paths.modelsCacheJson).map { $0.slug })
        XCTAssertEqual(store.topLevelValue(of: "model_catalog_json"), paths.catalogJson.path)
    }

    func testSwitchingBetweenProvidersRefreshesTheSameCatalog() throws {
        try writeNative()
        let selectable = ProviderCatalog.default.providers.filter { !$0.isReserved }
        for provider in selectable {
            _ = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: provider.id)

            let data = try Data(contentsOf: paths.catalogJson)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let models = try XCTUnwrap(object["models"] as? [[String: Any]])
            // Every routed provider is exposed under Codex's own slugs, while the
            // display name still names the provider answering.
            XCTAssertEqual(models.map { $0["slug"] as? String },
                           ModelMasquerade.aliases(for: provider, cacheURL: paths.modelsCacheJson).map { $0.slug },
                           provider.id)
            XCTAssertTrue(models.allSatisfy {
                ($0["display_name"] as? String)?.hasSuffix(" · \(provider.displayName)") == true
            }, provider.id)
        }
    }

    func testSelectionOrderKeepsOverrideAndCatalogInSync() throws {
        try writeNative()
        let selectable = ProviderCatalog.default.providers.filter { !$0.isReserved }

        for provider in selectable {
            let model = provider.defaultModel
            _ = try store.applyOverride(provider: provider, model: model)
            _ = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: provider.id)

            let exposed = ModelMasquerade.slug(for: model, provider: provider, cacheURL: paths.modelsCacheJson)
            XCTAssertEqual(store.topLevelValue(of: "model"), exposed, provider.id)
            XCTAssertEqual(store.topLevelValue(of: "model_provider"), provider.id, provider.id)
            XCTAssertEqual(store.overrideState()?.model, model, provider.id)
            XCTAssertEqual(store.overrideState()?.exposedModel, exposed, provider.id)
            let data = try Data(contentsOf: paths.catalogJson)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let models = try XCTUnwrap(object["models"] as? [[String: Any]])
            // The slug written to config.toml must exist in the catalog Codex reads.
            XCTAssertTrue(models.contains { $0["slug"] as? String == exposed }, provider.id)
        }
    }

    func testUserOwnedCatalogAfterTomlSectionIsPreserved() throws {
        try writeNative()
        let userCatalog = home.appendingPathComponent("user-models.json")
        let userJSON = "{\"models\":[{\"slug\":\"user-model\"}]}"
        try userJSON.write(to: userCatalog, atomically: true, encoding: .utf8)
        var config = try store.readConfig()
        config += "\nmodel_catalog_json = \"\(userCatalog.path)\"\n"
        try config.write(to: paths.configToml, atomically: true, encoding: .utf8)

        let report = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "openrouter")

        XCTAssertFalse(report.catalogInstalled)
        XCTAssertEqual(try String(contentsOf: userCatalog, encoding: .utf8), userJSON)
        let resultingConfig = try store.readConfig()
        XCTAssertNil(store.topLevelValue(of: "model_catalog_json"))
        XCTAssertTrue(resultingConfig.contains("model_catalog_json = \"\(userCatalog.path)\""))
        XCTAssertEqual(resultingConfig.components(separatedBy: "model_catalog_json = ").count - 1, 1)
        XCTAssertFalse(resultingConfig.contains("# >>> provider-switcher catalog >>>"))
    }

    func testOpenAISelectionRemovesManagedCatalogAfterTomlSection() throws {
        try writeNative()
        let configPath = paths.catalogJson.path
        let catalog = CodexConfigGenerator.catalogJSON(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "deepseek",
            cacheURL: paths.modelsCacheJson
        )
        try catalog.write(to: paths.catalogJson, atomically: true, encoding: .utf8)
        var config = try store.readConfig()
        config += "\n# >>> provider-switcher catalog >>>\n"
        config += "model_catalog_json = \"\(configPath)\"\n"
        config += "# <<< provider-switcher catalog >>>\n"
        try config.write(to: paths.configToml, atomically: true, encoding: .utf8)

        XCTAssertTrue(try store.installCatalog(
            providers: ProviderCatalog.default.providers,
            activeProviderID: "openai"
        ))
        let resultingConfig = try store.readConfig()
        XCTAssertFalse(resultingConfig.contains("model_catalog_json = \"\(configPath)\""))
        XCTAssertFalse(resultingConfig.contains("# >>> provider-switcher catalog >>>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.catalogJson.path))
    }

    func testUserOwnedCatalogAtDefaultPathIsPreserved() throws {
        try writeNative()
        let userCatalog = paths.catalogJson
        try "{\"models\":[{\"slug\":\"my-model\"}]}".write(to: userCatalog, atomically: true, encoding: .utf8)
        var config = try store.readConfig()
        config = config.replacingOccurrences(
            of: "model_provider = \"openai\"\n",
            with: "model_provider = \"openai\"\nmodel_catalog_json = \"\(userCatalog.path)\"\n"
        )
        try config.write(to: paths.configToml, atomically: true, encoding: .utf8)

        let report = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "claude")

        XCTAssertFalse(report.catalogInstalled)
        XCTAssertEqual(try String(contentsOf: userCatalog, encoding: .utf8), "{\"models\":[{\"slug\":\"my-model\"}]}")
        XCTAssertTrue((try store.readConfig()).contains("model_catalog_json = \"\(userCatalog.path)\""))
    }

    func testInstallIsIdempotent() throws {
        try writeNative()
        _ = try store.install(providers: ProviderCatalog.default.providers)
        let report = try store.install(providers: ProviderCatalog.default.providers)
        XCTAssertTrue(report.providersAdded.isEmpty)
        XCTAssertTrue(report.providersAlreadyPresent.contains("deepseek"))
        let config = try store.readConfig()
        // Only one deepseek block.
        XCTAssertEqual(config.components(separatedBy: "[model_providers.deepseek]").count - 1, 1)
    }

    func testUserOwnedCatalogAtDifferentPathIsPreserved() throws {
        try writeNative()
        let userCatalog = home.appendingPathComponent("my-models.json")
        try "{\"models\":[{\"slug\":\"my-model\"}]}".write(to: userCatalog, atomically: true, encoding: .utf8)
        var config = try store.readConfig()
        config = config.replacingOccurrences(
            of: "model_provider = \"openai\"\n",
            with: "model_provider = \"openai\"\nmodel_catalog_json = \"\(userCatalog.path)\"\n"
        )
        try config.write(to: paths.configToml, atomically: true, encoding: .utf8)

        let report = try store.install(providers: ProviderCatalog.default.providers, activeProviderID: "claude")

        XCTAssertFalse(report.catalogInstalled)
        XCTAssertTrue((try store.readConfig()).contains("model_catalog_json = \"\(userCatalog.path)\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userCatalog.path))
    }

    // MARK: Override (reversible)

    func testApplyOverrideEditsOnlyTopLevelAndPreservesRest() throws {
        try writeNative()
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.install(providers: ProviderCatalog.default.providers)
        let state = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")

        let config = try store.readConfig()
        // Codex reads one of its own slugs; the real model lives in the sidecar.
        let exposed = ModelMasquerade.slug(for: "deepseek-v4-flash", provider: deepseek,
                                           cacheURL: paths.modelsCacheJson)
        XCTAssertNotEqual(exposed, "deepseek-v4-flash")
        XCTAssertTrue(config.contains("model = \"\(exposed)\""))
        XCTAssertTrue(config.contains("model_provider = \"deepseek\""))
        XCTAssertEqual(state.model, "deepseek-v4-flash")
        XCTAssertEqual(state.exposedModel, exposed)
        XCTAssertTrue(config.contains("[mcp_servers.github]"))           // preserved
        XCTAssertTrue(config.contains("[model_providers.deepseek]"))      // preserved
        // Native model line is replaced by the override.
        XCTAssertFalse(config.range(of: #"^\s*model = "gpt-5\.6""#, options: .regularExpression) != nil)

        XCTAssertEqual(state.nativeModel, "gpt-5.6")
        XCTAssertEqual(state.nativeModelProvider, "openai")
        XCTAssertTrue(store.hasOverride())
    }

    func testRevertOverrideRestoresNative() throws {
        try writeNative()
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.install(providers: ProviderCatalog.default.providers)
        _ = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")

        let reverted = try store.revertOverride()
        XCTAssertTrue(reverted)
        XCTAssertFalse(store.hasOverride())

        let config = try store.readConfig()
        XCTAssertTrue(config.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(config.contains("model_provider = \"openai\""))
        XCTAssertTrue(config.contains("[mcp_servers.github]"))
        // The override block is gone.
        XCTAssertFalse(config.contains("model_provider = \"deepseek\""))
    }

    func testRevertWithoutOverrideIsNoop() throws {
        try writeNative()
        let result = try store.revertOverride()
        XCTAssertFalse(result)
    }

    func testRevertRemovesLegacyManagedOverrideWithoutSidecar() throws {
        try writeNative()
        let legacy = """
        # >>> provider-switcher override >>>
        model = "deepseek-v4-flash"
        model_provider = "deepseek"
        # <<< provider-switcher override <<<

        """
        try legacy.write(to: paths.configToml, atomically: true, encoding: .utf8)

        XCTAssertTrue(try store.revertOverride())
        let config = try store.readConfig()
        XCTAssertTrue(config.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(config.contains("model_provider = \"openai\""))
        XCTAssertFalse(config.contains("deepseek-v4-flash"))
        XCTAssertFalse(config.contains("# >>> provider-switcher override >>>"))
    }

    // MARK: Uninstall (full reversibility)

    func testUninstallRemovesEverything() throws {
        try writeNative()
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.install(providers: ProviderCatalog.default.providers)
        _ = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")

        _ = try store.uninstall()

        let config = try store.readConfig()
        XCTAssertFalse(config.contains("[model_providers.deepseek]"))
        XCTAssertFalse(config.contains("provider-switcher"))
        XCTAssertFalse(config.contains("web_search = true"))
        // Native config restored.
        XCTAssertTrue(config.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(config.contains("[mcp_servers.github]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("deepseek.config.toml").path))
    }

    // MARK: Fresh start

    func testInstallOnMissingCodexHomeCreatesIt() throws {
        // No config.toml at all.
        let report = try store.install(providers: ProviderCatalog.default.providers)
        XCTAssertTrue(report.providersAdded.contains("deepseek"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configToml.path))
    }

    func testOverrideNoKeyInConfigOrState() throws {
        try writeNative()
        // Simulate a key being present in memory; it must never reach config/state.
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.install(providers: ProviderCatalog.default.providers)
        _ = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")
        let config = try store.readConfig()
        let stateData = try Data(contentsOf: paths.stateJson)
        let combined = (config + (String(data: stateData, encoding: .utf8) ?? ""))
        XCTAssertFalse(combined.contains("sk-"))
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(config))
    }
}
