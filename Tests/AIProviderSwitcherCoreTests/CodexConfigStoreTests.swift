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

        // No key anywhere.
        XCTAssertFalse(CodexConfigGenerator.containsKeyLikeField(config))

        // Profile files written (openai skipped).
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("deepseek.config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexHome.appendingPathComponent("openai.config.toml").path))
        XCTAssertNotNil(report.backupWritten)
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

    // MARK: Override (reversible)

    func testApplyOverrideEditsOnlyTopLevelAndPreservesRest() throws {
        try writeNative()
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.install(providers: ProviderCatalog.default.providers)
        let state = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")

        let config = try store.readConfig()
        XCTAssertTrue(config.contains("model = \"deepseek-v4-flash\""))
        XCTAssertTrue(config.contains("model_provider = \"deepseek\""))
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
