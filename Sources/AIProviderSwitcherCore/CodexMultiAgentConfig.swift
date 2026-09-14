import Foundation

/// How `~/.codex/config.toml` came to describe Codex Multi-Agent V2.
///
/// Proxycodex is strictly additive: it only ever rewrites the block it wrote
/// itself, and a configuration the user typed by hand is reported — never
/// silently replaced.
public enum CodexMultiAgentConfigSource: String, Sendable, Equatable {
    /// No Multi-Agent V2 entry at all: Codex uses its own default (the feature
    /// is stable, but disabled by default).
    case absent
    /// Written by Proxycodex, between its `provider-switcher multi-agent`
    /// markers. Safe to update and to remove.
    case proxycodexManaged
    /// Present in `config.toml` without Proxycodex markers: the user owns it.
    case userManaged
}

/// The Codex Multi-Agent V2 settings Proxycodex reads, and writes only when it
/// owns the block:
///
/// ```toml
/// [features.multi_agent_v2]
/// enabled = true
/// max_concurrent_threads_per_session = 8
/// ```
///
/// `maxConcurrentThreads` counts **every** thread of the session, the main
/// agent included. It is therefore never the number of sub-agents: 8 threads
/// means “1 main agent + up to 7 sub-agents” (see ``maxSubagents``).
public struct CodexMultiAgentConfig: Sendable, Equatable {
    /// Proxycodex default when it enables Multi-Agent for the first time.
    public static let defaultThreads = 8
    /// `max_concurrent_threads_per_session = 1` is legal but delegates nothing.
    public static let minimumThreads = 1
    /// Highest value the store accepts. Codex itself allows more, but such a
    /// session has no practical use and would drain the quota.
    public static let maximumThreads = 64
    /// Highest value the panel offers in its custom field.
    public static let recommendedMaximumThreads = 40

    public let enabled: Bool
    public let maxConcurrentThreads: Int
    public let source: CodexMultiAgentConfigSource

    public init(
        enabled: Bool,
        maxConcurrentThreads: Int = CodexMultiAgentConfig.defaultThreads,
        source: CodexMultiAgentConfigSource
    ) {
        self.enabled = enabled
        self.maxConcurrentThreads = max(1, maxConcurrentThreads)
        self.source = source
    }

    /// Codex default when nothing is configured.
    public static func absent() -> CodexMultiAgentConfig {
        CodexMultiAgentConfig(enabled: false, source: .absent)
    }

    /// Sub-agents Codex *may* run in parallel: every thread except the main
    /// agent. `0` means the setting cannot delegate anything.
    public var maxSubagents: Int {
        max(0, maxConcurrentThreads - 1)
    }

    public var isUserManaged: Bool { source == .userManaged }
    public var isManagedByProxycodex: Bool { source == .proxycodexManaged }
    /// True when an entry exists in `config.toml` (whatever wrote it).
    public var isConfigured: Bool { source != .absent }

    /// Preset matching the current thread count (`.custom` when none does).
    public var preset: MultiAgentPreset {
        MultiAgentPreset.preset(for: maxConcurrentThreads)
    }

    public var concurrencyLevel: MultiAgentConcurrencyLevel {
        MultiAgentConcurrencyLevel(threads: maxConcurrentThreads)
    }

    /// Same configuration with individual fields replaced. Used after a write
    /// so the panel reflects what `config.toml` now says.
    public func updating(
        enabled: Bool? = nil,
        maxConcurrentThreads: Int? = nil,
        source: CodexMultiAgentConfigSource? = nil
    ) -> CodexMultiAgentConfig {
        CodexMultiAgentConfig(
            enabled: enabled ?? self.enabled,
            maxConcurrentThreads: maxConcurrentThreads ?? self.maxConcurrentThreads,
            source: source ?? self.source
        )
    }
}

/// Presets offered by the panel. Thread counts stay small on purpose: the
/// number includes the main agent, and every extra thread is another
/// concurrent consumer of the Codex quota.
public enum MultiAgentPreset: String, CaseIterable, Sendable, Identifiable {
    case economical
    case recommended
    case intensive
    case veryIntensive
    case custom

    public var id: String { rawValue }

    /// Threads this preset writes, `nil` for the free-form custom value.
    public var threadCount: Int? {
        switch self {
        case .economical: return 4
        case .recommended: return CodexMultiAgentConfig.defaultThreads
        case .intensive: return 12
        case .veryIntensive: return 16
        case .custom: return nil
        }
    }

    /// The preset matching a thread count, `.custom` when none does.
    public static func preset(for threads: Int) -> MultiAgentPreset {
        allCases.first { $0.threadCount == threads } ?? .custom
    }
}

/// How aggressive a thread count is, and what the panel warns about.
public enum MultiAgentConcurrencyLevel: Sendable, Equatable {
    /// `1` thread: the session cannot delegate at all.
    case noSubagents
    /// 2–7 threads.
    case moderate
    /// 8–11 threads (the recommended default).
    case recommended
    /// 12–15 threads.
    case high
    /// 16–23 threads.
    case veryHigh
    /// 24 threads and above: 429s and fast quota burn become likely.
    case risky

    public init(threads: Int) {
        switch threads {
        case ..<2: self = .noSubagents
        case 2...7: self = .moderate
        case 8...11: self = .recommended
        case 12...15: self = .high
        case 16...23: self = .veryHigh
        default: self = .risky
        }
    }
}

/// Reading of the *current* quota, used only to phrase a recommendation.
/// Purely informational: Proxycodex never throttles the user's setting itself.
public enum MultiAgentQuotaAdvice: Sendable, Equatable {
    /// No window exposed (provider without quota, or quota not read yet).
    case unavailable
    /// 70 % or more remaining.
    case comfortable
    /// 40–69 % remaining.
    case adequate
    /// 20–39 % remaining.
    case limited
    /// Less than 20 % remaining.
    case low

    public init(remainingPercent: Double?) {
        guard let remainingPercent, remainingPercent.isFinite else {
            self = .unavailable
            return
        }
        switch remainingPercent {
        case 70...: self = .comfortable
        case 40...: self = .adequate
        case 20...: self = .limited
        default: self = .low
        }
    }

    /// Threads the panel suggests for this reading — never written anywhere.
    public var suggestedThreads: Int? {
        switch self {
        case .unavailable: return nil
        case .comfortable, .adequate: return CodexMultiAgentConfig.defaultThreads
        case .limited, .low: return 4
        }
    }
}

/// Text-level reader for `[features.multi_agent_v2]` in `config.toml`.
///
/// Deliberately not a TOML encoder: Proxycodex edits `config.toml` as text so
/// comments, ordering and every other user section survive untouched. The same
/// rule applies here — this type only *reads*.
public enum CodexMultiAgentTOML {
    public static let beginMarker = "# >>> provider-switcher multi-agent >>>"
    public static let endMarker = "# <<< provider-switcher multi-agent <<<"

    /// Managed block first (the markers prove ownership), then a hand-written
    /// `[features.multi_agent_v2]` table or a `[features]` inline table — both
    /// belong to the user.
    public static func config(in configText: String) -> CodexMultiAgentConfig {
        let lines = configText.components(separatedBy: "\n")

        if let block = managedBlockLines(in: lines) {
            let fields = fields(in: block)
            return CodexMultiAgentConfig(
                enabled: fields.enabled ?? false,
                maxConcurrentThreads: fields.threads ?? CodexMultiAgentConfig.defaultThreads,
                source: .proxycodexManaged
            )
        }

        if let user = userManagedFields(in: lines) {
            return CodexMultiAgentConfig(
                enabled: user.enabled ?? false,
                maxConcurrentThreads: user.threads ?? CodexMultiAgentConfig.defaultThreads,
                source: .userManaged
            )
        }

        return .absent()
    }

    /// Lines between the two `provider-switcher multi-agent` markers, when the
    /// block is complete.
    static func managedBlockLines(in lines: [String]) -> [String]? {
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if start == nil, trimmed == beginMarker {
                start = index + 1
                continue
            }
            if let begin = start, trimmed == endMarker {
                return Array(lines[begin..<index])
            }
        }
        return nil
    }

    /// A `[features.multi_agent_v2]` table, or the inline form inside
    /// `[features]`, written without Proxycodex markers.
    static func userManagedFields(in lines: [String]) -> (enabled: Bool?, threads: Int?)? {
        if let table = tableLines(named: "[features.multi_agent_v2]", in: lines) {
            return fields(in: table)
        }
        for line in (tableLines(named: "[features]", in: lines) ?? []) where line.contains("multi_agent_v2") {
            return fields(in: [line])
        }
        return nil
    }

    /// Body of a table header: every line up to the next table header.
    static func tableLines(named header: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            body.append(line)
        }
        return body
    }

    static func fields(in lines: [String]) -> (enabled: Bool?, threads: Int?) {
        var enabled: Bool?
        var threads: Int?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            if enabled == nil, let value = boolValue(of: "enabled", in: trimmed) {
                enabled = value
            }
            if threads == nil,
               let value = intValue(of: "max_concurrent_threads_per_session", in: trimmed),
               value >= CodexMultiAgentConfig.minimumThreads {
                threads = value
            }
        }
        return (enabled, threads)
    }

    /// `key = true` / `key = false`, including the inline-table form
    /// (`multi_agent_v2 = { enabled = true }`).
    static func boolValue(of key: String, in line: String) -> Bool? {
        guard let value = rawValue(of: key, in: line) else { return nil }
        let token = value.prefix { !$0.isWhitespace && $0 != "," && $0 != "}" }
        switch token {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func intValue(of key: String, in line: String) -> Int? {
        guard let value = rawValue(of: key, in: line) else { return nil }
        let digits = value.prefix { $0.isNumber || $0 == "_" }
        guard !digits.isEmpty else { return nil }
        return Int(digits.replacingOccurrences(of: "_", with: ""))
    }

    /// Everything after `key =` on `line`, whatever surrounds the assignment
    /// (start of line, a comma or an opening brace in an inline table).
    private static func rawValue(of key: String, in line: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?:^|[,\\{])\\s*" + escaped + "\\s*=\\s*(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (line as NSString).substring(with: match.range(at: 1))
    }
}
