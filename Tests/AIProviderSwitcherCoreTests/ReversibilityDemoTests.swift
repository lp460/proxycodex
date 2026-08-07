import XCTest
@testable import AIProviderSwitcherCore

/// Visual demonstration (prints to stdout) of the additive + reversible behavior.
final class ReversibilityDemoTests: XCTestCase {
    func testDemonstrateFullCycle() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        let paths = CodexPaths(
            codexHome: home,
            configToml: home.appendingPathComponent("config.toml"),
            stateJson: home.appendingPathComponent("state.json"),
            backupDir: home.appendingPathComponent("backups"),
            catalogJson: home.appendingPathComponent("catalog.json"),
            modelsCacheJson: home.appendingPathComponent("models_cache.json")
        )
        let store = CodexConfigStore(paths: paths)
        defer { try? FileManager.default.removeItem(at: home) }

        let native = """
        # === MA CONFIG CODEX/OPENAI (ne doit jamais être modifiée) ===
        model = "gpt-5.6"
        model_provider = "openai"

        [mcp_servers.github]
        command = "npx"
        """
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try native.write(to: paths.configToml, atomically: true, encoding: .utf8)

        print("\n━━━ 0) CONFIG NATIVE (avant) ━━━\n\(try store.readConfig())")

        _ = try store.install(providers: ProviderCatalog.default.providers)
        print("\n━━━ 1) APRÈS INSTALL (additif : OpenAI inchangé, providers ajoutés) ━━━\n\(try store.readConfig())")

        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        _ = try store.applyOverride(provider: deepseek, model: "deepseek-v4-flash")
        print("\n━━━ 2) APRÈS SÉLECTION DeepSeek (override top-level réversible) ━━━\n\(try store.readConfig())")

        _ = try store.revertOverride()
        print("\n━━━ 3) RETOUR OPENAI (override supprimé, natif restauré) ━━━\n\(try store.readConfig())")

        _ = try store.uninstall()
        print("\n━━━ 4) APRÈS DÉSINSTALLATION ( état natif pur ) ━━━\n\(try store.readConfig())")

        // Assertions that prove the contract.
        let final = try store.readConfig()
        XCTAssertTrue(final.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(final.contains("model_provider = \"openai\""))
        XCTAssertTrue(final.contains("[mcp_servers.github]"))
        XCTAssertFalse(final.contains("provider-switcher"))
        XCTAssertFalse(final.contains("[model_providers.deepseek]"))
    }
}
