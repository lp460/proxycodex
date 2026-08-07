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

public enum CodexConfigError: Error, LocalizedError {
    case cannotReadConfig(URL)
    case reservedProviderDeclared(String)
    public var errorDescription: String? {
        switch self {
        case .cannotReadConfig(let url): return "Cannot read \(url.path)"
        case .reservedProviderDeclared(let id): return "Refused to redeclare reserved provider '\(id)'"
        }
    }
}

/// Reversible state captured when an override is applied, so it can be undone.
public struct OverrideState: Codable, Equatable, Sendable {
    public let nativeModel: String?          // original top-level `model` value (nil if absent)
    public let nativeModelProvider: String?  // original top-level `model_provider` value (nil ⇒ openai default)
    public let provider: String
    public let model: String
    public let appliedAt: Date
}

public struct InstallReport: Equatable, Sendable {
    public let providersAdded: [String]      // ids whose [model_providers.<id>] was appended
    public let providersAlreadyPresent: [String]
    public let profilesWritten: [String]
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
        let backupURL = try backup()
        var config = try readConfig()
        var added: [String] = []
        var present: [String] = []
        var profiles: [String] = []
        var blockChanged = false

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
                try CodexConfigGenerator.profileFile(model: provider.defaultModel, providerID: provider.id)
                    .write(to: url, atomically: true, encoding: .utf8)
                profiles.append(provider.id)
            }
        }

        if !added.isEmpty || blockChanged {
            try writeConfig(config)
        }
        _ = present
        // Static catalog for the active provider: the Desktop picker then only
        // lists that provider's models.
        try installCatalog(providers: providers, activeProviderID: activeProviderID)
        return InstallReport(
            providersAdded: added,
            providersAlreadyPresent: present,
            profilesWritten: profiles,
            backupWritten: backupURL
        )
    }

    /// Installs the static model catalog for the ACTIVE provider: only its own
    /// models are listed in the Desktop picker. OpenAI (native) removes the
    /// catalog entirely so the picker shows pure ChatGPT.
    @discardableResult
    public func installCatalog(providers: [Provider], activeProviderID: String) throws -> Bool {
        var config = try readConfig()
        var changed = false
        let active = providers.first { $0.id == activeProviderID }
        if let active, !active.isReserved || active.id == "ollama" {
            let json = CodexConfigGenerator.catalogJSON(
                providers: providers,
                activeProviderID: activeProviderID,
                cacheURL: paths.modelsCacheJson
            )
            try json.write(to: paths.catalogJson, atomically: true, encoding: .utf8)
            config = removeManagedBlocksNamed("catalog", in: config)
            if !config.contains("model_catalog_json") {
                let body = "model_catalog_json = \(quote(paths.catalogJson.path))\n"
                config = prependBlock(config, wrappedBlock(name: "catalog", body: body))
                changed = true
            }
        } else {
            // Native OpenAI: remove the static catalog.
            config = removeManagedBlocksNamed("catalog", in: config)
            if FileManager.default.fileExists(atPath: paths.catalogJson.path) {
                try? FileManager.default.removeItem(at: paths.catalogJson)
            }
            changed = true
        }
        if changed { try writeConfig(config) }
        return true
    }

    /// Removes every block/profile this app added and reverts any active override.
    @discardableResult
    public func uninstall() throws -> Bool {
        var changed = try revertOverride()
        var config = try readConfig()
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
        // Remove the static model catalog we wrote.
        if FileManager.default.fileExists(atPath: paths.catalogJson.path) {
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

        let body = "model = \(quote(model))\nmodel_provider = \(quote(provider.id))\n"
        config = prependBlock(config, wrappedBlock(name: "override", body: body))

        try backup()
        try writeConfig(config)

        let state = OverrideState(
            nativeModel: nativeModel,
            nativeModelProvider: nativeProvider,
            provider: provider.id,
            model: model,
            appliedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: paths.stateJson, options: [.atomic])
        try restrict(stateURL: paths.stateJson)
        return state
    }

    /// Restores the native top-level model/model_provider and clears the sidecar.
    @discardableResult
    public func revertOverride() throws -> Bool {
        guard let state = overrideState() else { return false }
        var config = try readConfig()
        config = removeOverrideBlock(in: config)
        config = removeTopLevelKey("model", in: config)
        config = removeTopLevelKey("model_provider", in: config)

        var restore: [String] = []
        if let m = state.nativeModel { restore.append("model = \(quote(m))") }
        if let p = state.nativeModelProvider { restore.append("model_provider = \(quote(p))") }
        if !restore.isEmpty {
            config = prependBlock(config, restore.joined(separator: "\n") + "\n")
        }
        try writeConfig(config)
        try? FileManager.default.removeItem(at: paths.stateJson)
        return true
    }

    // MARK: Low-level line editing

    private func writeConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try text.write(to: paths.configToml, atomically: true, encoding: .utf8)
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

    private func removeManagedBlocks(in config: String) -> String {
        var t = config
        for name in ["override", "catalog", "provider:deepseek", "provider:glm", "provider:openrouter", "provider:ollama", "provider:lmstudio"] {
            t = removeManagedBlocksNamed(name, in: t)
        }
        // Also strip any provider block for catalog ids (custom) generically.
        for provider in ProviderCatalog.default.providers {
            t = removeManagedBlocksNamed("provider:\(provider.id)", in: t)
        }
        return t
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
