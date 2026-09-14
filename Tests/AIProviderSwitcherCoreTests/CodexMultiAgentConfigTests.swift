import XCTest
@testable import AIProviderSwitcherCore

/// Codex Multi-Agent V2: reading, ownership, additive writing.
///
/// The rule under test everywhere: Proxycodex owns **only** the block it wrote
/// between its own markers. A hand-written `[features.multi_agent_v2]` is
/// reported as `userManaged` and never edited, and every other line of
/// `config.toml` — comments, `[features]` keys, nested tables — survives.
final class CodexMultiAgentConfigTests: XCTestCase {
    var home: URL!
    var paths: CodexPaths!
    var store: CodexConfigStore!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("aps-ma-\(UUID().uuidString)")
        paths = CodexPaths(
            codexHome: home,
            configToml: home.appendingPathComponent("config.toml"),
            stateJson: home.appendingPathComponent("state.json"),
            backupDir: home.appendingPathComponent("backups"),
            catalogJson: home.appendingPathComponent("catalog.json"),
            modelsCacheJson: home.appendingPathComponent("models_cache.json")
        )
        store = CodexConfigStore(paths: paths)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func write(_ text: String) throws {
        try text.write(to: paths.configToml, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOf: paths.configToml, encoding: .utf8)
    }

    // MARK: Detection

    /// No Multi-Agent entry: Codex keeps its own (disabled) default.
    func testAbsentConfigIsReportedAsAbsent() throws {
        try write("""
        model = "gpt-5.6"

        [features]
        web_search = true
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.source, .absent)
        XCTAssertEqual(config.maxConcurrentThreads, CodexMultiAgentConfig.defaultThreads)
    }

    func testMissingConfigFileIsAbsent() throws {
        let config = try store.readMultiAgentConfig()
        XCTAssertEqual(config, .absent())
    }

    func testManagedBlockIsDetected() throws {
        try write("""
        model = "gpt-5.6"

        # >>> provider-switcher multi-agent >>>
        [features.multi_agent_v2]
        enabled = true
        max_concurrent_threads_per_session = 8
        # <<< provider-switcher multi-agent <<<
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, 8)
        XCTAssertEqual(config.source, .proxycodexManaged)
        XCTAssertEqual(config.maxSubagents, 7)
    }

    /// A block Proxycodex wrote, then disabled: still owned by the app, still
    /// readable as “off”.
    func testManagedDisabledBlockIsDetected() throws {
        try write("""
        # >>> provider-switcher multi-agent >>>
        [features.multi_agent_v2]
        enabled = false
        max_concurrent_threads_per_session = 12
        # <<< provider-switcher multi-agent <<<
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, 12)
        XCTAssertEqual(config.source, .proxycodexManaged)
    }

    /// The user's own table, without markers: `userManaged`, and 16 stays 16.
    func testUserManagedTableIsNeverReportedAsManaged() throws {
        try write("""
        [features.multi_agent_v2]
        enabled = true
        max_concurrent_threads_per_session = 16
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, 16)
        XCTAssertEqual(config.source, .userManaged)
        XCTAssertEqual(config.maxSubagents, 15)
    }

    /// Inline form inside an existing `[features]` table.
    func testUserManagedInlineTableIsDetected() throws {
        try write("""
        [features]
        web_search = true
        multi_agent_v2 = { enabled = true, max_concurrent_threads_per_session = 4 }
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, 4)
        XCTAssertEqual(config.source, .userManaged)
    }

    /// A malformed value must not take the whole bootstrap down.
    func testUnparsableThreadValueFallsBackToDefault() throws {
        try write("""
        [features.multi_agent_v2]
        enabled = yes
        max_concurrent_threads_per_session = "eight"
        """)
        let config = try store.readMultiAgentConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, CodexMultiAgentConfig.defaultThreads)
        XCTAssertEqual(config.source, .userManaged)
    }

    // MARK: Writing

    func testActivatingFromAbsentWritesTheManagedBlock() throws {
        try write("""
        model = "gpt-5.6"
        """)
        let written = try store.setMultiAgentConfig(enabled: true, threads: 8)
        XCTAssertEqual(written.source, .proxycodexManaged)

        let config = try read()
        XCTAssertTrue(config.contains(CodexMultiAgentTOML.beginMarker))
        XCTAssertTrue(config.contains(CodexMultiAgentTOML.endMarker))
        XCTAssertTrue(config.contains("[features.multi_agent_v2]"))
        XCTAssertTrue(config.contains("enabled = true"))
        XCTAssertTrue(config.contains("max_concurrent_threads_per_session = 8"))
        XCTAssertTrue(config.contains("model = \"gpt-5.6\""))
        // Default is the recommended preset, never 40.
        XCTAssertEqual(try store.readMultiAgentConfig().maxSubagents, 7)
    }

    /// An existing `[features]` table and a nested `[features.other]` must both
    /// survive, and the result must still be valid TOML.
    func testActivationPreservesSiblingFeatureTables() throws {
        try write("""
        # mon commentaire
        model = "gpt-5.6"

        [features]
        web_search = true

        [features.other]
        value = 42
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 8)
        let config = try read()

        XCTAssertTrue(config.contains("# mon commentaire"))
        XCTAssertTrue(config.contains("[features]"))
        XCTAssertTrue(config.contains("web_search = true"))
        XCTAssertTrue(config.contains("[features.other]"))
        XCTAssertTrue(config.contains("value = 42"))
        // Exactly one `[features]` header, and one sub-table header.
        XCTAssertEqual(config.components(separatedBy: "\n").filter { $0 == "[features]" }.count, 1)
        XCTAssertEqual(config.components(separatedBy: "\n").filter { $0 == "[features.other]" }.count, 1)
        try XCTAssertValidTOML(config)
    }

    func testChangingThreadsOnlyRewritesTheManagedBlock() throws {
        try write("""
        [features]
        web_search = true
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 8)
        let before = try read()

        let updated = try store.setMultiAgentConfig(enabled: true, threads: 12)
        XCTAssertEqual(updated.maxConcurrentThreads, 12)
        XCTAssertEqual(updated.maxSubagents, 11)

        let after = try read()
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(withoutManagedBlock(before), withoutManagedBlock(after))
        XCTAssertTrue(after.contains("max_concurrent_threads_per_session = 12"))
        XCTAssertFalse(after.contains("max_concurrent_threads_per_session = 8"))
        XCTAssertEqual(after.components(separatedBy: "provider-switcher multi-agent").count - 1, 2, "one begin + one end marker")
    }

    /// Disabling keeps the block (reversible) and every other feature intact.
    func testDisablingKeepsOtherFeaturesIntact() throws {
        try write("""
        [features]
        web_search = true
        foo = true
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 16)
        try store.setMultiAgentConfig(enabled: false, threads: 16)

        let config = try store.readMultiAgentConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.maxConcurrentThreads, 16)
        XCTAssertEqual(config.source, .proxycodexManaged)

        let text = try read()
        XCTAssertTrue(text.contains("web_search = true"))
        XCTAssertTrue(text.contains("foo = true"))
        XCTAssertTrue(text.contains("enabled = false"))
        try XCTAssertValidTOML(text)
    }

    /// Writing the identical state must not touch the file (Codex reconnects on
    /// every change, so a no-op write is a visible hiccup).
    func testIdenticalWriteLeavesFileUntouched() throws {
        try write("""
        model = "gpt-5.6"
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 8)
        let first = try read()
        let backupsAfterFirst = try FileManager.default.contentsOfDirectory(atPath: paths.backupDir.path).count

        try store.setMultiAgentConfig(enabled: true, threads: 8)
        XCTAssertEqual(try read(), first)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.backupDir.path).count,
            backupsAfterFirst,
            "an unchanged config must not create a new backup"
        )
    }

    // MARK: Thread bounds

    func testAcceptedThreadCounts() throws {
        for threads in [1, 4, 8, 12, 16, 40] {
            try write("model = \"gpt-5.6\"\n")
            XCTAssertNoThrow(try store.setMultiAgentConfig(enabled: true, threads: threads))
            let config = try store.readMultiAgentConfig()
            XCTAssertEqual(config.maxConcurrentThreads, threads)
            XCTAssertEqual(config.maxSubagents, max(0, threads - 1))
        }
    }

    func testRefusedThreadCounts() throws {
        try write("model = \"gpt-5.6\"\n")
        for threads in [0, -1, -40, CodexMultiAgentConfig.maximumThreads + 1] {
            XCTAssertThrowsError(try store.setMultiAgentConfig(enabled: true, threads: threads)) { error in
                XCTAssertEqual(error as? CodexConfigError, .invalidMultiAgentThreads(threads))
            }
        }
        XCTAssertFalse(try read().contains("multi_agent_v2"))
    }

    // MARK: Ownership protection

    func testWriteRefusedWhenConfigurationIsUserManaged() throws {
        let original = """
        [features.multi_agent_v2]
        enabled = true
        max_concurrent_threads_per_session = 16
        """
        try write(original)

        XCTAssertThrowsError(try store.setMultiAgentConfig(enabled: true, threads: 8)) { error in
            XCTAssertEqual(error as? CodexConfigError, .multiAgentIsUserManaged)
        }
        // 16 must never become 8, and no marker may appear.
        XCTAssertEqual(try read(), original)
        XCTAssertFalse(try read().contains("provider-switcher multi-agent"))
        XCTAssertEqual(try store.readMultiAgentConfig().maxConcurrentThreads, 16)
    }

    func testRemovingManagedBlockKeepsOtherSections() throws {
        try write("""
        [features]
        web_search = true

        [features.other]
        value = 42
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 8)
        XCTAssertTrue(try store.removeManagedMultiAgentConfig())
        let text = try read()
        XCTAssertFalse(text.contains("provider-switcher multi-agent"))
        XCTAssertTrue(text.contains("web_search = true"))
        XCTAssertTrue(text.contains("[features.other]"))
        XCTAssertEqual(try store.readMultiAgentConfig().source, .absent)
        XCTAssertFalse(try store.removeManagedMultiAgentConfig(), "second removal is a no-op")
    }

    // MARK: Interaction with the rest of the installer

    /// The install pass re-appends `[tools]`; the managed Multi-Agent block must
    /// survive it, and the resulting file must stay valid TOML.
    func testInstallKeepsMultiAgentBlockAndStaysValidTOML() throws {
        try write("""
        model = "gpt-5.6"

        [features]
        web_search = true
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 12)
        try store.install(providers: ProviderCatalog.default.providers)

        let text = try read()
        XCTAssertTrue(text.contains("provider-switcher multi-agent"))
        XCTAssertTrue(text.contains("max_concurrent_threads_per_session = 12"))
        XCTAssertTrue(text.contains("[model_providers.deepseek]"))
        XCTAssertTrue(text.contains("web_search = true"))
        XCTAssertEqual(try store.readMultiAgentConfig().maxConcurrentThreads, 12)
        try XCTAssertValidTOML(text)
    }

    /// Uninstall removes the managed block — and only that.
    func testUninstallRemovesManagedMultiAgentBlock() throws {
        try write("""
        model = "gpt-5.6"

        [features]
        web_search = true
        """)
        try store.setMultiAgentConfig(enabled: true, threads: 8)
        try store.install(providers: ProviderCatalog.default.providers)
        try store.uninstall()

        let text = try read()
        XCTAssertFalse(text.contains("provider-switcher multi-agent"))
        XCTAssertFalse(text.contains("[features.multi_agent_v2]"))
        XCTAssertTrue(text.contains("web_search = true"))
        XCTAssertTrue(text.contains("model = \"gpt-5.6\""))
    }

    // MARK: Semantics

    func testThreadsNeverMeanSubagents() {
        let eight = CodexMultiAgentConfig(enabled: true, maxConcurrentThreads: 8, source: .proxycodexManaged)
        XCTAssertEqual(eight.maxSubagents, 7)
        XCTAssertEqual(CodexMultiAgentConfig(enabled: true, maxConcurrentThreads: 4, source: .proxycodexManaged).maxSubagents, 3)
        XCTAssertEqual(CodexMultiAgentConfig(enabled: true, maxConcurrentThreads: 12, source: .proxycodexManaged).maxSubagents, 11)
        XCTAssertEqual(CodexMultiAgentConfig(enabled: true, maxConcurrentThreads: 16, source: .proxycodexManaged).maxSubagents, 15)
        XCTAssertEqual(CodexMultiAgentConfig(enabled: true, maxConcurrentThreads: 1, source: .proxycodexManaged).maxSubagents, 0)
    }

    func testPresetMapping() {
        XCTAssertEqual(MultiAgentPreset.preset(for: 4), .economical)
        XCTAssertEqual(MultiAgentPreset.preset(for: 8), .recommended)
        XCTAssertEqual(MultiAgentPreset.preset(for: 12), .intensive)
        XCTAssertEqual(MultiAgentPreset.preset(for: 16), .veryIntensive)
        XCTAssertEqual(MultiAgentPreset.preset(for: 7), .custom)
        XCTAssertEqual(MultiAgentPreset.preset(for: 40), .custom)
        XCTAssertEqual(MultiAgentPreset.recommended.threadCount, 8)
        XCTAssertEqual(MultiAgentPreset.economical.threadCount, 4)
        XCTAssertNil(MultiAgentPreset.custom.threadCount)
        XCTAssertEqual(MultiAgentPreset.allCases.count, 5)
    }

    func testConcurrencyLevels() {
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 1), .noSubagents)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 4), .moderate)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 8), .recommended)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 12), .high)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 16), .veryHigh)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 24), .risky)
        XCTAssertEqual(MultiAgentConcurrencyLevel(threads: 40), .risky)
    }

    func testQuotaAdviceBuckets() {
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: nil), .unavailable)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 78), .comfortable)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 70), .comfortable)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 55), .adequate)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 25), .limited)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 14), .low)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 0), .low)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: .nan), .unavailable)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 14).suggestedThreads, 4)
        XCTAssertEqual(MultiAgentQuotaAdvice(remainingPercent: 78).suggestedThreads, 8)
        XCTAssertNil(MultiAgentQuotaAdvice.unavailable.suggestedThreads)
    }

    // MARK: Helpers

    /// Everything the app did not write: used to prove that changing the thread
    /// count only rewrites the managed block.
    private func withoutManagedBlock(_ text: String) -> String {
        var kept: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == CodexMultiAgentTOML.beginMarker {
                skipping = true
                continue
            }
            if trimmed == CodexMultiAgentTOML.endMarker {
                skipping = false
                continue
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Real TOML validation through `tomllib`, when a Python 3.11+ interpreter
    /// is available. Skipped (not failed) otherwise, so the suite stays portable.
    private func XCTAssertValidTOML(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = home.appendingPathComponent("validation-\(UUID().uuidString).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let script = """
        import sys
        try:
            import tomllib
        except ImportError:
            sys.exit(2)
        tomllib.load(open(sys.argv[1], 'rb'))
        """
        for candidate in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["-c", script, url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 2 {
                throw XCTSkip("python3 without tomllib: TOML validation skipped")
            }
            XCTAssertEqual(process.terminationStatus, 0, "config.toml is not valid TOML", file: file, line: line)
            return
        }
        throw XCTSkip("no python3 available: TOML validation skipped")
    }
}
