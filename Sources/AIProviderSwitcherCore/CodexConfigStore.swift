import Foundation

/// Where Codex lives and where AI Provider Switcher keeps its side-car state.
public struct CodexPaths: Sendable {
    public let codexHome: URL
    public let configToml: URL
    public let stateJson: URL
    public let backupDir: URL
    public let catalogJson: URL
    public let modelsCacheJson: URL

    /// Resolves from `CODEX_HOME` env, else `~/.codex`.
    public static func defaultPaths() -> CodexPaths {
        let home: URL
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            home = URL(fileURLWithPath: env)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return CodexPaths(
            codexHome: home,
            configToml: home.appendingPathComponent("config.toml"),
            stateJson: home.appendingPathComponent("provider-switcher-state.json"),
            backupDir: home.appendingPathComponent("backup-provider-switcher"),
            catalogJson: home.appendingPathComponent("catalog.json"),
            modelsCacheJson: home.appendingPathComponent("models_cache.json")
        )
    }
}

public enum CodexConfigError: Error, LocalizedError, Equatable {
    case cannotReadConfig(URL)
    case reservedProviderDeclared(String)
    /// `config.toml` already carries a hand-written Multi-Agent entry: the user
    /// owns it, and Proxycodex refuses to touch it.
    case multiAgentIsUserManaged
    case invalidMultiAgentThreads(Int)
    public var errorDescription: String? {
        switch self {
        case .cannotReadConfig(let url): return "Cannot read \(url.path)"
        case .reservedProviderDeclared(let id): return "Refused to redeclare reserved provider '\(id)'"
        case .multiAgentIsUserManaged:
            return "Multi-Agent V2 is configured by hand in config.toml"
        case .invalidMultiAgentThreads(let threads):
            return "Refused Multi-Agent thread count \(threads)"
        }
    }
}

/// Reversible state captured when an override is applied, so it can be undone.
public struct OverrideState: Codable, Equatable, Sendable {
    public let nativeModel: String?          // original top-level `model` value (nil if absent)
    public let nativeModelProvider: String?  // original top-level `model_provider` value (nil ⇒ openai default)
    public let provider: String
    public let model: String                 // real provider model (what the panel shows)
    /// Slug written to `config.toml`, i.e. what Codex believes it is talking to.
    /// Absent in states written before model masquerading existed.
    public let exposedModel: String?
    public let appliedAt: Date

    public init(
        nativeModel: String?,
        nativeModelProvider: String?,
        provider: String,
        model: String,
        exposedModel: String? = nil,
        appliedAt: Date
    ) {
        self.nativeModel = nativeModel
        self.nativeModelProvider = nativeModelProvider
        self.provider = provider
        self.model = model
        self.exposedModel = exposedModel
        self.appliedAt = appliedAt
    }
}

public struct InstallReport: Equatable, Sendable {
    public let providersAdded: [String]      // ids whose [model_providers.<id>] was appended
    public let providersAlreadyPresent: [String]
    public let profilesWritten: [String]
    public let catalogInstalled: Bool       // false when a user-owned catalog key wins
    public let backupWritten: URL?
}

/// Manages `~/.codex/config.toml` as a **strictly additive, reversible** layer.
///
/// - Install (once): appends `[model_providers.<id>]` blocks (never redeclares
///   the reserved `openai`/`ollama`/`lmstudio`) and writes profile files.
/// - Select (Desktop/IDE): edits ONLY the top-level `model` + `model_provider`
///   lines, preserving every other line/comment; the original values are saved
///   to a sidecar so "OpenAI / Native" fully restores them.
/// - Codex CLI selection uses `codex --profile <id>` + an env-key, no edit here.
public final class CodexConfigStore: Sendable {
    public let paths: CodexPaths
    public init(paths: CodexPaths = .defaultPaths()) {
        self.paths = paths
    }

    // MARK: Read / backup

    public func readConfig() throws -> String {
        guard FileManager.default.fileExists(atPath: paths.configToml.path) else { return "" }
        return (try? String(contentsOf: paths.configToml, encoding: .utf8)) ?? ""
    }

    @discardableResult
    public func backup() throws -> URL? {
        guard FileManager.default.fileExists(atPath: paths.configToml.path) else { return nil }
        try FileManager.default.createDirectory(at: paths.backupDir, withIntermediateDirectories: true)
        let stamp = Self.fileFormatter.string(from: Date())
        // Ensure a unique name even when several writes happen in the same second.
        var dst = paths.backupDir.appendingPathComponent("config.toml.\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = paths.backupDir.appendingPathComponent("config.toml.\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: paths.configToml, to: dst)
        return dst
    }

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: Install (additive)

    @discardableResult
    public func install(providers: [Provider], activeProviderID: String = "openai") throws -> InstallReport {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        var backupURL: URL?
        var config = try readConfig()
        var added: [String] = []
        var present: [String] = []
        var profiles: [String] = []
        var blockChanged = false

        // The tools block is re-appended at the end by installToolsConfig, so it
        // is dropped here to keep a single deterministic layout.
        config = removeManagedBlocksNamed("tools", in: config)
        for provider in providers {
            // Never redeclare reserved built-in providers.
            if provider.isReserved {
                if providerTableHeader(for: provider.id, in: config) {
                    throw CodexConfigError.reservedProviderDeclared(provider.id)
                }
            } else {
                // Refresh the managed block so base_url stays current (e.g. the
                // local adapter proxy ports), then append the fresh one.
                let existed = providerTableHeader(for: provider.id, in: config)
                config = removeManagedBlocksNamed("provider:\(provider.id)", in: config)
                let block = wrappedBlock(name: "provider:\(provider.id)", body: CodexConfigGenerator.providerBlock(provider))
                config = appendBlock(config, block)
                if existed {
                    present.append(provider.id)
                } else {
                    added.append(provider.id)
                }
                blockChanged = true
            }
            // Profile file for every selectable provider (OpenAI = native, no profile).
            if provider.id != "openai" {
                let url = paths.codexHome.appendingPathComponent("\(provider.id).config.toml")
                // Codex CLI must see the same masqueraded slug as the Desktop.
                let exposed = ModelMasquerade.slug(
                    for: provider.defaultModel,
                    provider: provider,
                    cacheURL: paths.modelsCacheJson
                )
                try CodexConfigGenerator.profileFile(model: exposed, providerID: provider.id)
                    .write(to: url, atomically: true, encoding: .utf8)
                profiles.append(provider.id)
            }
        }

        _ = present
        _ = blockChanged
        // Static catalog for the active provider: the Desktop picker then only
        // lists that provider's models. A user-owned model_catalog_json is
        // preserved and reported instead of being silently overridden.
        let (withCatalog, catalogInstalled) = try applyingCatalog(
            config, providers: providers, activeProviderID: activeProviderID)
        // Codex's native web search flag is independent from the model catalog.
        // `[tools]` is re-appended last, always, so the managed layout is stable:
        // an order that alternates between runs is a real change of the file, and
        // Codex reloads (and reconnects) on every change.
        config = installToolsConfig(in: withCatalog)
        // ONE write for the whole selection: providers, catalog and tools.
        backupURL = try writeConfig(config)
        return InstallReport(
            providersAdded: added,
            providersAlreadyPresent: present,
            profilesWritten: profiles,
            catalogInstalled: catalogInstalled,
            backupWritten: backupURL
        )
    }

    /// Installs the static model catalog for the ACTIVE provider: only its own
    /// models are listed in the Desktop picker. OpenAI (native) removes the
    /// catalog entirely so the picker shows pure ChatGPT.
    @discardableResult
    public func installCatalog(providers: [Provider], activeProviderID: String) throws -> Bool {
        let (config, installed) = try applyingCatalog(
            try readConfig(), providers: providers, activeProviderID: activeProviderID)
        try writeConfig(installToolsConfig(in: config))
        return installed
    }

    /// Catalog + `[tools]` decisions as a pure text transform, so a whole
    /// selection can be written in a single change of config.toml.
    private func applyingCatalog(
        _ input: String,
        providers: [Provider],
        activeProviderID: String
    ) throws -> (String, Bool) {
        var config = input
        var catalogInstalled = false
        let active = providers.first { $0.id == activeProviderID }
        if let active, !active.isReserved || active.id == "ollama" {
            // Only the explicit managed block proves ownership. A user may
            // intentionally point Codex at ~/.codex/catalog.json, so the path
            // alone must never authorize overwriting that file.
            let catalogMarker = "# >>> provider-switcher catalog >>>"
            let existingCatalogPath = topLevelValue(of: "model_catalog_json", in: config)
                ?? catalogAssignmentValue(in: config)
            let legacyGeneratedCatalog = catalogAssignmentValue(in: config) == paths.catalogJson.path
                && (try? Data(contentsOf: paths.catalogJson)).map {
                    CodexConfigGenerator.isGeneratedCatalog($0, providers: providers)
                } == true
            let appOwnsCatalog = config.contains(catalogMarker) || legacyGeneratedCatalog
            let hadUserCatalog = existingCatalogPath != nil && !appOwnsCatalog
            config = removeManagedBlocksNamed("catalog", in: config)
            if appOwnsCatalog {
                config = removeTopLevelKey("model_catalog_json", in: config)
                // Older builds could append the managed assignment after a
                // TOML section. Once ownership is proven by the marker or a
                // generated legacy file, remove it wherever it occurs.
                config = removeCatalogAssignment(in: config)
            }
            if !hadUserCatalog && topLevelValue(of: "model_catalog_json", in: config) == nil {
                let json = CodexConfigGenerator.catalogJSON(
                    providers: providers,
                    activeProviderID: activeProviderID,
                    cacheURL: paths.modelsCacheJson
                )
                try json.write(to: paths.catalogJson, atomically: true, encoding: .utf8)
                let body = "model_catalog_json = \(quote(paths.catalogJson.path))\n"
                config = prependBlock(config, wrappedBlock(name: "catalog", body: body))
                catalogInstalled = true
            }
        } else {
            // Native OpenAI: remove only the catalog managed by this app.
            let catalogMarker = "# >>> provider-switcher catalog >>>"
            let existingCatalogPath = topLevelValue(of: "model_catalog_json", in: config)
                ?? catalogAssignmentValue(in: config)
            let legacyGeneratedCatalog = catalogAssignmentValue(in: config) == paths.catalogJson.path
                && (try? Data(contentsOf: paths.catalogJson)).map {
                    CodexConfigGenerator.isGeneratedCatalog($0, providers: ProviderCatalog.default.providers)
                } == true
            let appOwnsCatalog = config.contains(catalogMarker) || legacyGeneratedCatalog
            let hadUserCatalog = existingCatalogPath != nil && !appOwnsCatalog
            let hadManagedCatalog = appOwnsCatalog
            config = removeManagedBlocksNamed("catalog", in: config)
            if appOwnsCatalog {
                config = removeTopLevelKey("model_catalog_json", in: config)
                // Older builds could append the managed assignment after a
                // TOML section. Once ownership is proven by the marker or a
                // generated legacy file, remove it wherever it occurs.
                config = removeCatalogAssignment(in: config)
            }
            if hadManagedCatalog, FileManager.default.fileExists(atPath: paths.catalogJson.path) {
                try? FileManager.default.removeItem(at: paths.catalogJson)
            }
            catalogInstalled = !hadUserCatalog
        }
        return (config, catalogInstalled)
    }

    /// Removes every block/profile this app added and reverts any active override.
    @discardableResult
    public func uninstall() throws -> Bool {
        var changed = try revertOverride()
        var config = try readConfig()
        let hadManagedCatalog = config.contains("# >>> provider-switcher catalog >>>")
        let cleaned = removeManagedBlocks(in: config)
        if cleaned != config {
            try writeConfig(cleaned)
            config = cleaned
            changed = true
        }
        // Remove profile files we may have written (non-openai providers).
        for provider in ProviderCatalog.default.providers where provider.id != "openai" {
            let url = paths.codexHome.appendingPathComponent("\(provider.id).config.toml")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                changed = true
            }
        }
        // Remove only the static model catalog managed by this app. A user-owned
        // model_catalog_json may point to the same path and must survive.
        if hadManagedCatalog, FileManager.default.fileExists(atPath: paths.catalogJson.path) {
            try? FileManager.default.removeItem(at: paths.catalogJson)
            changed = true
        }
        _ = config
        return changed
    }

    // MARK: Override (reversible top-level model/model_provider edit)

    public func hasOverride() -> Bool {
        FileManager.default.fileExists(atPath: paths.stateJson.path)
    }

    /// Current top-level `key = "value"` (before any `[section]`), if any.
    public func topLevelValue(of key: String) -> String? {
        guard let config = try? readConfig() else { return nil }
        return topLevelValue(of: key, in: config)
    }

    public func overrideState() -> OverrideState? {
        guard let data = try? Data(contentsOf: paths.stateJson) else { return nil }
        return try? JSONDecoder().decode(OverrideState.self, from: data)
    }

    /// Edits ONLY the top-level `model` + `model_provider` of config.toml so that
    /// Desktop/IDE clients (which read config at launch) use `provider`/`model`.
    /// The original values are saved to the sidecar for a full restore.
    @discardableResult
    public func applyOverride(provider: Provider, model: String) throws -> OverrideState {
        precondition(!provider.isReserved || provider.id == "ollama" || provider.id == "lmstudio",
                     "OpenAI is selected by reverting the override, not by applying one.")
        var config = try readConfig()
        let existing = overrideState()

        // Snapshot native values only the first time we override.
        let nativeModel: String?
        let nativeProvider: String?
        if let existing {
            nativeModel = existing.nativeModel
            nativeProvider = existing.nativeModelProvider
        } else {
            nativeModel = topLevelValue(of: "model", in: config)
            nativeProvider = topLevelValue(of: "model_provider", in: config)
        }

        // Remove any previous override block + stray top-level model/model_provider lines.
        config = removeOverrideBlock(in: config)
        config = removeTopLevelKey("model", in: config)
        config = removeTopLevelKey("model_provider", in: config)

        // Codex reads the slug, not the provider's real model name: a routed
        // provider is exposed under one of Codex's own slugs so its full native
        // feature contract applies (see ModelMasquerade).
        let exposed = ModelMasquerade.slug(for: model, provider: provider, cacheURL: paths.modelsCacheJson)
        let body = "model = \(quote(exposed))\nmodel_provider = \(quote(provider.id))\n"
        config = prependBlock(config, wrappedBlock(name: "override", body: body))

        try writeConfig(config)

        let state = OverrideState(
            nativeModel: nativeModel,
            nativeModelProvider: nativeProvider,
            provider: provider.id,
            model: model,
            exposedModel: exposed,
            appliedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: paths.stateJson, options: [.atomic])
        try restrict(stateURL: paths.stateJson)
        return state
    }

    /// True when config.toml already carries exactly this managed selection, so
    /// nothing has to be rewritten — Codex changed the model itself and the file
    /// is already what we would have written.
    public func selectionMatchesConfig(provider: Provider, exposedModel: String) -> Bool {
        guard let config = try? readConfig(),
              config.contains("# >>> \(beginToken) override >>>"),
              topLevelValue(of: "model", in: config) == exposedModel,
              topLevelValue(of: "model_provider", in: config) == provider.id else { return false }
        return true
    }

    /// Records a selection in the sidecar only, leaving config.toml untouched.
    /// Used when Codex itself wrote the model we would have written.
    @discardableResult
    public func recordSelection(provider: Provider, model: String, exposedModel: String) throws -> OverrideState {
        let existing = overrideState()
        let state = OverrideState(
            nativeModel: existing?.nativeModel ?? topLevelValue(of: "model"),
            nativeModelProvider: existing?.nativeModelProvider ?? topLevelValue(of: "model_provider"),
            provider: provider.id,
            model: model,
            exposedModel: exposedModel,
            appliedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: paths.stateJson, options: [.atomic])
        try restrict(stateURL: paths.stateJson)
        return state
    }

    /// Restores the native top-level model/model_provider and clears the sidecar.
    ///
    /// Older builds could write the managed override block before the sidecar
    /// state file. In that case, OpenAI must still be able to remove the stale
    /// managed block instead of returning early and leaving DeepSeek active.
    @discardableResult
    public func revertOverride(allowLegacyUnmarked: Bool = false) throws -> Bool {
        let state = overrideState()
        var config = try readConfig()
        let hadManagedBlock = config.contains("# >>> \(beginToken) override >>>")
        let currentModel = topLevelValue(of: "model", in: config)
        let currentProvider = topLevelValue(of: "model_provider", in: config)
        let hadLegacyUnmarkedOverride = allowLegacyUnmarked && state == nil && !hadManagedBlock
            && currentProvider.map { providerID in
                guard providerID != "openai",
                      let provider = ProviderCatalog.default[id: providerID],
                      let currentModel else { return false }
                if provider.models.contains(currentModel) { return true }
                // A masqueraded selection stores one of Codex's own slugs in
                // `model`, so the real model name is not in config.toml.
                return ModelMasquerade.masquerades(provider)
                    && ModelMasquerade.aliases(for: provider, cacheURL: paths.modelsCacheJson)
                        .contains { $0.slug == currentModel }
            } == true
        guard state != nil || hadManagedBlock || hadLegacyUnmarkedOverride else { return false }

        config = removeOverrideBlock(in: config)
        config = removeTopLevelKey("model", in: config)
        config = removeTopLevelKey("model_provider", in: config)

        var restore: [String] = []
        if let m = state?.nativeModel {
            restore.append("model = \(quote(m))")
        } else if hadManagedBlock || hadLegacyUnmarkedOverride {
            // Safe fallback for overrides written by pre-sidecar builds.
            let nativeModel = ProviderCatalog.default[id: "openai"]?.defaultModel ?? "gpt-5.6"
            restore.append("model = \(quote(nativeModel))")
        }
        if let p = state?.nativeModelProvider {
            restore.append("model_provider = \(quote(p))")
        } else if hadManagedBlock || hadLegacyUnmarkedOverride {
            restore.append("model_provider = \"openai\"")
        }
        if !restore.isEmpty {
            config = prependBlock(config, restore.joined(separator: "\n") + "\n")
        }
        try writeConfig(config)
        try? FileManager.default.removeItem(at: paths.stateJson)
        return true
    }

    // MARK: Low-level line editing

    /// Writes config.toml **only** when the content actually changes.
    ///
    /// Codex watches the file: every write makes it reload its configuration and
    /// reconnect, so a rewrite with identical content is a visible hiccup for the
    /// user (and a useless backup on disk).
    /// Collapses runs of two or more blank lines.
    ///
    /// Managed blocks are removed and re-appended on every install, and each
    /// removal leaves the blank line that preceded it. Without this, config.toml
    /// grows by one empty line per provider per install — and, worse, every
    /// install then differs from the file on disk, so Codex reloads and drops its
    /// connection each time. Single blank lines, which users write themselves,
    /// are left alone.
    private func collapsingBlankRuns(_ text: String) -> String {
        var out: [String] = []
        var blanks = 0
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks > 1 { continue }
            } else {
                blanks = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    @discardableResult
    private func writeConfig(_ rawText: String) throws -> URL? {
        let text = collapsingBlankRuns(rawText)
        let current = try? String(contentsOf: paths.configToml, encoding: .utf8)
        guard current != text else { return nil }
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let backupURL = current != nil ? try backup() : nil
        try text.write(to: paths.configToml, atomically: true, encoding: .utf8)
        return backupURL
    }

    private func restrict(stateURL: URL) throws {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: stateURL.path)
    }

    private func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func providerTableHeader(for id: String, in config: String) -> Bool {
        // Match the exact table header anywhere in the file (the brackets make it
        // unambiguous; the id is regex-escaped).
        let pattern = "\\[model_providers\\." + NSRegularExpression.escapedPattern(for: id) + "\\]"
        return config.range(of: pattern, options: .regularExpression) != nil
    }

    /// Finds the value of a top-level `key = "value"` line (before any `[section]`).
    private func topLevelValue(of key: String, in config: String) -> String? {
        let regex = try? NSRegularExpression(
            pattern: "^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*\"(.*)\"\\s*$"
        )
        var inSection = false
        for line in config.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inSection = true }
            if inSection { continue }
            if let r = regex {
                let ns = line as NSString
                if let m = r.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                    return ns.substring(with: m.range(at: 1))
                }
            }
        }
        return nil
    }

    /// Finds a quoted assignment anywhere in the file. Used only for
    /// migrating legacy app-owned catalog entries that were written after a
    /// TOML section by older versions.
    private func catalogAssignmentValue(in config: String) -> String? {
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("model_catalog_json") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "model_catalog_json" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.first == "\"", value.last == "\"" else { continue }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    private func removeCatalogAssignment(in config: String) -> String {
        config.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") || !trimmed.hasPrefix("model_catalog_json")
        }.joined(separator: "\n")
    }

    /// Removes top-level `key = ...` lines (before the first `[section]`).
    private func removeTopLevelKey(_ key: String, in config: String) -> String {
        let lines = config.components(separatedBy: "\n")
        let regex = try? NSRegularExpression(
            pattern: "^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*="
        )
        var inSection = false
        var out: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inSection = true }
            if !inSection, let r = regex {
                let ns = line as NSString
                if r.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                    continue // drop this top-level key line
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Marked blocks

    private let beginToken = "provider-switcher"
    private func wrappedBlock(name: String, body: String) -> String {
        "# >>> \(beginToken) \(name) >>>\n\(body)# <<< \(beginToken) \(name) <<<\n"
    }

    private func appendBlock(_ config: String, _ block: String) -> String {
        var t = config
        if !t.hasSuffix("\n") && !t.isEmpty { t += "\n" }
        if !t.isEmpty { t += "\n" }
        t += block
        return t
    }

    private func prependBlock(_ config: String, _ block: String) -> String {
        block + (config.isEmpty ? "" : "\n" + config)
    }

    private func removeOverrideBlock(in config: String) -> String {
        removeManagedBlocksNamed("override", in: config)
    }

    // MARK: Multi-Agent V2 (additive, only ever its own marked block)

    /// Reads `[features.multi_agent_v2]`, flagged with the ownership the file
    /// proves: Proxycodex markers, hand-written by the user, or absent.
    public func readMultiAgentConfig() throws -> CodexMultiAgentConfig {
        CodexMultiAgentTOML.config(in: try readConfig())
    }

    /// Writes (or updates) the managed Multi-Agent block. Only the marked block
    /// is touched: other `[features]` keys, nested tables and comments stay
    /// byte-for-byte identical.
    ///
    /// Refuses to write when the user manages the setting themselves, and when
    /// the thread count is out of the supported range.
    @discardableResult
    public func setMultiAgentConfig(enabled: Bool, threads: Int) throws -> CodexMultiAgentConfig {
        guard threads >= CodexMultiAgentConfig.minimumThreads,
              threads <= CodexMultiAgentConfig.maximumThreads else {
            throw CodexConfigError.invalidMultiAgentThreads(threads)
        }
        var config = try readConfig()
        guard !CodexMultiAgentTOML.config(in: config).isUserManaged else {
            throw CodexConfigError.multiAgentIsUserManaged
        }
        config = removeManagedBlocksNamed("multi-agent", in: config)
        let block = wrappedBlock(
            name: "multi-agent",
            body: multiAgentBody(enabled: enabled, threads: threads)
        )
        // Kept before the managed `[tools]` block when there is one, so the
        // managed layout stays deterministic across installs and edits.
        config = insertBlock(block, beforeManagedBlock: "tools", in: config)
        try writeConfig(config)
        return CodexMultiAgentConfig(
            enabled: enabled,
            maxConcurrentThreads: threads,
            source: .proxycodexManaged
        )
    }

    /// Removes the managed Multi-Agent block, leaving any user-written entry in
    /// place. Returns whether anything changed.
    @discardableResult
    public func removeManagedMultiAgentConfig() throws -> Bool {
        let config = try readConfig()
        let cleaned = removeManagedBlocksNamed("multi-agent", in: config)
        guard cleaned != config else { return false }
        try writeConfig(cleaned)
        return true
    }

    private func multiAgentBody(enabled: Bool, threads: Int) -> String {
        var lines = ["[features.multi_agent_v2]"]
        lines.append("enabled = \(enabled)")
        lines.append("max_concurrent_threads_per_session = \(threads)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Inserts a marked block just before another marked block, or at the end
    /// of the file when that block is absent.
    private func insertBlock(_ block: String, beforeManagedBlock name: String, in config: String) -> String {
        let marker = "# >>> \(beginToken) \(name) >>>"
        guard let range = config.range(of: marker) else {
            return appendBlock(config, block)
        }
        var text = config
        text.insert(contentsOf: block, at: range.lowerBound)
        return text
    }

    private func removeManagedBlocks(in config: String) -> String {
        var t = config
        for name in ["override", "catalog", "tools", "multi-agent", "provider:deepseek", "provider:glm", "provider:openrouter", "provider:ollama", "provider:lmstudio"] {
            t = removeManagedBlocksNamed(name, in: t)
        }
        // Also strip any provider block for catalog ids (custom) generically.
        for provider in ProviderCatalog.default.providers {
            t = removeManagedBlocksNamed("provider:\(provider.id)", in: t)
        }
        return t
    }

    private func installToolsConfig(in config: String) -> String {
        let clean = removeManagedBlocksNamed("tools", in: config)
        var lines = clean.components(separatedBy: "\n")
        if let toolsIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[tools]" }) {
            var end = lines.count
            if toolsIndex + 1 < lines.count {
                for index in (toolsIndex + 1)..<lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                        end = index
                        break
                    }
                }
            }
            // A user-owned `web_search` must win: inserting a second assignment
            // in the same table makes Codex reject config.toml entirely.
            let ownsWebSearch = lines[(toolsIndex + 1)..<end].contains {
                $0.range(of: #"^\s*web_search\s*="#, options: .regularExpression) != nil
            }
            guard !ownsWebSearch else { return clean }
            lines.insert("# >>> \(beginToken) tools >>>", at: toolsIndex + 1)
            lines.insert("web_search = true", at: toolsIndex + 2)
            lines.insert("# <<< \(beginToken) tools <<<", at: toolsIndex + 3)
            return lines.joined(separator: "\n")
        }
        return appendBlock(clean, wrappedBlock(name: "tools", body: "[tools]\nweb_search = true\n"))
    }

    private func removeManagedBlocksNamed(_ name: String, in config: String) -> String {
        let begin = "# >>> \(beginToken) \(name) >>>"
        let end = "# <<< \(beginToken) \(name) <<<"
        var result: [String] = []
        var skipping = false
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !skipping {
                if trimmed == begin {
                    skipping = true
                    continue
                }
                result.append(line)
            } else if trimmed == end {
                skipping = false
                continue
            }
            // while skipping, lines inside the block are dropped
        }
        return result.joined(separator: "\n")
    }
}
