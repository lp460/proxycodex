import Foundation

/// What Proxycodex has really *observed* about a provider+model running a Codex
/// Multi-Agent V2 workflow.
///
/// This is deliberately not a capability claim. It is a record of protocol
/// events seen in real sessions: Proxycodex never launches a request of its own
/// to certify a model, and a model that simply never delegates stays `unknown`,
/// which is a perfectly good answer.
public enum MultiAgentCompatibilityStatus: String, Codable, Sendable, Equatable {
    /// Never seen: the model was not asked to delegate, or it did not.
    case unknown
    /// The model really emitted a namespaced call the bridge restored, but the
    /// full cycle is not proven yet.
    case observed
    /// A real sub-agent cycle completed: call restored, executed, child thread
    /// created, result returned.
    case validated
    /// A reproducible technical incompatibility was demonstrated. Reserved for
    /// protocol-level failures only: never for quota, auth or network problems.
    case incompatible
    /// No conclusion possible: the attempt stopped on provider, auth, quota or
    /// network trouble.
    case inconclusive
    /// A previous conclusion, invalidated because the bridge contract changed.
    /// Re-observation happens on the next real use — never by a launched test.
    case stale

    /// The status to show when a record carries no conclusion.
    public var isConclusion: Bool {
        self == .validated || self == .incompatible
    }
}

/// Everything recorded for one provider+model pair. Contains no secret, no
/// prompt and no tool argument.
public struct MultiAgentCapabilityRecord: Codable, Sendable, Equatable {
    public var status: MultiAgentCompatibilityStatus
    /// When a full cycle was proven.
    public var validatedAt: Date?
    /// Last time *anything* was observed, including a non-conclusive attempt.
    public var lastObservedAt: Date?
    /// Machine-readable reason for the last non-conclusive attempt
    /// (`rate_limited`, `insufficient_balance`, ...). Kept even when the status
    /// stays `validated`, so a temporary outage is remembered without
    /// invalidating the conclusion.
    public var reason: String?
    /// Codex version that produced the observation, when known.
    public var codexVersion: String?
    /// Bridge contract version in force at observation time.
    public var bridgeVersion: Int?

    public init(
        status: MultiAgentCompatibilityStatus = .unknown,
        validatedAt: Date? = nil,
        lastObservedAt: Date? = nil,
        reason: String? = nil,
        codexVersion: String? = nil,
        bridgeVersion: Int? = nil
    ) {
        self.status = status
        self.validatedAt = validatedAt
        self.lastObservedAt = lastObservedAt
        self.reason = reason
        self.codexVersion = codexVersion
        self.bridgeVersion = bridgeVersion
    }
}

/// One `providerID + modelID` pair. The provider is part of the key on purpose:
/// `grok-4.6` through OpenCode Go and `grok-4.6` through OpenRouter are two
/// different backends and must never share a conclusion.
public struct ModelCapabilityRecord: Codable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public var multiAgent: MultiAgentCapabilityRecord

    public init(providerID: String, modelID: String,
                multiAgent: MultiAgentCapabilityRecord = MultiAgentCapabilityRecord()) {
        self.providerID = providerID
        self.modelID = modelID
        self.multiAgent = multiAgent
    }

    /// Stable storage key.
    public var key: String { "\(providerID)/\(modelID)" }
}

/// How a provider reaches Codex, which decides what a status can even mean.
public enum MultiAgentSupportPath: Sendable, Equatable {
    /// OpenAI native: Codex talks to its own backend, no adapter bridge.
    case nativeCodex
    /// A routed provider served through `provider-proxy.py`.
    case bridged
    /// A provider Codex implements itself without an adapter (Ollama).
    case unbridged
}

/// What the panel should say for the active provider+model.
public struct MultiAgentCompatibility: Sendable, Equatable {
    public let path: MultiAgentSupportPath
    public let record: MultiAgentCapabilityRecord?

    public init(path: MultiAgentSupportPath, record: MultiAgentCapabilityRecord?) {
        self.path = path
        self.record = record
    }

    /// `unknown` whenever nothing has been proven — including the native path,
    /// where "expected to work" is not the same thing as "observed working".
    public var status: MultiAgentCompatibilityStatus {
        path == .nativeCodex ? .unknown : (record?.status ?? .unknown)
    }

    public var reason: String? { record?.reason }
    public var validatedAt: Date? { record?.validatedAt }
}

/// One structured line written by `provider-proxy.py`. Technical metadata only.
public struct MultiAgentEvent: Codable, Sendable, Equatable {
    public enum Name: String, Sendable {
        /// Codex's namespaced tools really reached this provider.
        case toolsBridged = "multi_agent_tools_bridged"
        /// The provider emitted a namespaced call, restored for Codex to run.
        case toolRestored = "multi_agent_tool_restored"
        /// Codex executed that call: the result came back for its `call_id`.
        case toolResult = "multi_agent_tool_result"
        /// A real child thread exists; the cycle provably happened.
        case childThread = "multi_agent_child_thread"
        /// The upstream refused the turn. Never a Multi-Agent conclusion.
        case upstreamError = "multi_agent_upstream_error"
        /// Reserved for a demonstrated protocol incompatibility.
        case incompatible = "multi_agent_incompatible"
    }

    public let name: Name
    public let provider: String?
    public let model: String?
    public let slug: String?
    public let namespace: String?
    public let tool: String?
    public let callID: String?
    public let reason: String?
    public let verdict: String?
    public let httpStatus: Int?
    public let bridgeVersion: Int?
    public let tools: [String]?
    public let observedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case event, provider, model, slug, namespace, tool, reason, verdict, tools
        case callID = "call_id"
        case httpStatus = "http_status"
        case bridgeVersion = "bridge_version"
        case observedAt = "observed_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .event)
        guard let name = Name(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container,
                debugDescription: "unknown Multi-Agent event \(raw)")
        }
        self.name = name
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.slug = try container.decodeIfPresent(String.self, forKey: .slug)
        self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        self.tool = try container.decodeIfPresent(String.self, forKey: .tool)
        self.callID = try container.decodeIfPresent(String.self, forKey: .callID)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
        self.verdict = try container.decodeIfPresent(String.self, forKey: .verdict)
        self.httpStatus = try container.decodeIfPresent(Int.self, forKey: .httpStatus)
        self.bridgeVersion = try container.decodeIfPresent(Int.self, forKey: .bridgeVersion)
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools)
        self.observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name.rawValue, forKey: .event)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(slug, forKey: .slug)
        try container.encodeIfPresent(namespace, forKey: .namespace)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(callID, forKey: .callID)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(verdict, forKey: .verdict)
        try container.encodeIfPresent(httpStatus, forKey: .httpStatus)
        try container.encodeIfPresent(bridgeVersion, forKey: .bridgeVersion)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(observedAt, forKey: .observedAt)
    }

    /// Provider+model this event speaks about, when it names both.
    public var modelKey: (providerID: String, modelID: String)? {
        guard let provider, !provider.isEmpty, let model, !model.isEmpty else { return nil }
        return (provider, model)
    }
}

/// Why an observation stopped short of a conclusion. Only these causes are
/// recorded: a quota, auth or network problem is not a compatibility verdict.
public enum MultiAgentFailureReason: String, Sendable, Equatable {
    case authenticationRequired = "authentication_required"
    case insufficientBalance = "insufficient_balance"
    case forbidden
    case endpointNotFound = "endpoint_not_found"
    case timeout
    case rateLimited = "rate_limited"
    case providerError = "provider_error"
    case network
    /// The provider refused the request itself (HTTP 400) — a malformed or
    /// unsupported field, not a Multi-Agent verdict.
    case invalidRequest = "invalid_request"
    /// The provider refused the request as unsupported (HTTP 422). Kept
    /// distinct from `invalidRequest`: a strict gateway rejecting one item is
    /// not proof the model cannot run a sub-agent at all.
    case unsupportedRequest = "unsupported_request"
    /// The provider answered outside its own protocol. Only recorded when the
    /// proxy can prove it; never inferred from a transport error.
    case providerProtocolError = "provider_protocol_error"
    case protocolIncompatible = "protocol_incompatible"
    case unknown

    public init(code: String?) {
        guard let code, !code.isEmpty else { self = .unknown; return }
        self = MultiAgentFailureReason(rawValue: code) ?? .unknown
    }

    /// French source string, used as the localization key like every other
    /// user-facing label in the app.
    public var localizationKey: String {
        switch self {
        case .authenticationRequired: return "Authentification requise"
        case .insufficientBalance: return "Quota insuffisant"
        case .forbidden: return "Accès refusé"
        case .endpointNotFound: return "Endpoint introuvable"
        case .timeout: return "Délai dépassé"
        case .rateLimited: return "Rate limit"
        case .providerError: return "Provider indisponible"
        case .network: return "Réseau indisponible"
        case .invalidRequest: return "Requête invalide"
        case .unsupportedRequest: return "Requête non supportée"
        case .providerProtocolError: return "Erreur de protocole fournisseur"
        case .protocolIncompatible: return "Incompatibilité de protocole"
        case .unknown: return "Cause inconnue"
        }
    }
}

/// A status transition worth telling the user about in the journal.
public struct MultiAgentCapabilityChange: Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let previous: MultiAgentCompatibilityStatus
    public let current: MultiAgentCompatibilityStatus
    public let reason: String?
}

/// Reads the proxy's structured observation log.
///
/// The proxy appends complete JSON lines and never rewrites the file; the app is
/// the only consumer, so it can drain what it read and leave a partial trailing
/// line for the next pass.
public struct MultiAgentEventLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        KeyStore.defaultPersistentURL()
            .deletingLastPathComponent()
            .appendingPathComponent("multi-agent-events.jsonl")
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Size of the pending log, used to skip a read when nothing changed.
    public func currentSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Consume every complete line, keeping an unfinished tail in place.
    ///
    /// A malformed line is dropped: one unreadable observation must never stop
    /// the rest of the log from being understood.
    public func drain() -> [MultiAgentEvent] {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forUpdating: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var events: [MultiAgentEvent] = []
        var consumed = 0
        var offset = 0
        for byte in data {
            offset += 1
            guard byte == 0x0A else { continue }
            let line = data[(consumed)..<offset]
            consumed = offset
            guard !line.isEmpty else { continue }
            if let event = try? decoder.decode(MultiAgentEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        let remainder = Data(data.suffix(from: consumed))
        if remainder.count != data.count {
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: remainder)
            try? handle.truncate(atOffset: UInt64(remainder.count))
        }
        return events
    }
}

/// Persisted Multi-Agent compatibility, learned passively from real sessions.
///
/// An actor because observations can arrive while other work is in flight, and
/// writes are atomic so a crash mid-save cannot corrupt the file.
public actor MultiAgentCapabilityStore {
    /// Bumped whenever the flatten/restore contract changes. A conclusion
    /// recorded under an older bridge becomes `stale` and is simply re-observed
    /// on the next real use — nothing is launched to re-certify it.
    public static let bridgeCapabilityVersion = 1

    public let url: URL
    private var records: [String: ModelCapabilityRecord] = [:]
    private var loaded = false

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        // The app's own side-car directory, beside the key store and the model
        // discovery cache. No secret ever lands here.
        KeyStore.defaultPersistentURL()
            .deletingLastPathComponent()
            .appendingPathComponent("model-capabilities.json")
    }

    @discardableResult
    public func load() -> [ModelCapabilityRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ModelCapabilityRecord].self, from: data) else {
            loaded = true
            return []
        }
        records = Dictionary(decoded.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        loaded = true
        // A conclusion recorded under an older bridge contract is re-observed
        // on its next real use, so it is downgraded here and persisted.
        var stale = false
        for (key, record) in records {
            let updated = Self.staling(record.multiAgent)
            guard updated != record.multiAgent else { continue }
            var changed = record
            changed.multiAgent = updated
            records[key] = changed
            stale = true
        }
        if stale { try? save() }
        return Array(records.values).sorted { $0.key < $1.key }
    }

    /// All records, oldest load included. Kept for the panel and for tests.
    public func all() -> [ModelCapabilityRecord] {
        if !loaded { _ = load() }
        return Array(records.values).sorted { $0.key < $1.key }
    }

    public func record(for providerID: String, modelID: String) -> MultiAgentCapabilityRecord? {
        if !loaded { _ = load() }
        return records[ModelCapabilityRecord(providerID: providerID, modelID: modelID).key]?.multiAgent
    }

    /// Apply one observation and persist only when something really changed.
    @discardableResult
    public func apply(_ event: MultiAgentEvent, codexVersion: String? = nil) -> MultiAgentCapabilityChange? {
        if !loaded { _ = load() }
        guard let (providerID, modelID) = event.modelKey else { return nil }
        let key = ModelCapabilityRecord(providerID: providerID, modelID: modelID).key
        let stored = records[key] ?? ModelCapabilityRecord(providerID: providerID, modelID: modelID)
        let previous = stored.multiAgent
        guard let updated = Self.applying(event, to: previous, codexVersion: codexVersion) else {
            return nil
        }
        var record = stored
        record.multiAgent = updated
        records[key] = record
        try? save()
        guard Self.isReportable(previous: previous, updated: updated) else { return nil }
        return MultiAgentCapabilityChange(
            providerID: providerID, modelID: modelID,
            previous: previous.status, current: updated.status,
            reason: updated.reason)
    }

    /// Apply many observations in one pass, saving once.
    @discardableResult
    public func apply(_ events: [MultiAgentEvent], codexVersion: String? = nil) -> [MultiAgentCapabilityChange] {
        if !loaded { _ = load() }
        let interrupted = Self.interruptedCycles(in: events)
        var changes: [MultiAgentCapabilityChange] = []
        var dirty = false
        for event in events {
            guard let (providerID, modelID) = event.modelKey else { continue }
            let key = ModelCapabilityRecord(providerID: providerID, modelID: modelID).key
            // A child thread that was followed by a provider failure is real
            // evidence of a spawn, but not of a completed cycle.
            if event.name == .childThread, interrupted.contains(key) { continue }
            let stored = records[key] ?? ModelCapabilityRecord(providerID: providerID, modelID: modelID)
            if let updated = Self.applying(event, to: stored.multiAgent, codexVersion: codexVersion) {
                var record = stored
                record.multiAgent = updated
                records[key] = record
                dirty = true
                if Self.isReportable(previous: stored.multiAgent, updated: updated) {
                    changes.append(MultiAgentCapabilityChange(
                        providerID: providerID, modelID: modelID,
                        previous: stored.multiAgent.status, current: updated.status,
                        reason: updated.reason))
                }
            }
        }
        if dirty { try? save() }
        return changes
    }

    /// Provider+model pairs whose batch created a child thread and then hit a
    /// provider failure: the sub-agent exists, but nothing proves its result
    /// reached the parent, so the cycle must not be called `validated`.
    static func interruptedCycles(in events: [MultiAgentEvent]) -> Set<String> {
        var births: [String: Int] = [:]
        var interrupted: Set<String> = []
        for (index, event) in events.enumerated() {
            guard let (providerID, modelID) = event.modelKey else { continue }
            let key = ModelCapabilityRecord(providerID: providerID, modelID: modelID).key
            switch event.name {
            case .childThread:
                births[key] = index
            case .upstreamError, .incompatible:
                if let birth = births[key], birth < index { interrupted.insert(key) }
            default:
                break
            }
        }
        return interrupted
    }

    /// Atomic write: a crash mid-save leaves the previous file intact.
    public func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Array(records.values).sorted { $0.key < $1.key })
            .write(to: url, options: [.atomic])
    }

    /// The deterministic state machine. Returns `nil` when an event carries no
    /// change at all, so the file is not rewritten for a repeated observation.
    ///
    /// Conservative by construction: infrastructure failures can never produce
    /// `incompatible`, and they never downgrade an established conclusion.
    static func applying(
        _ event: MultiAgentEvent,
        to record: MultiAgentCapabilityRecord,
        codexVersion: String?
    ) -> MultiAgentCapabilityRecord? {
        var updated = record
        updated.codexVersion = codexVersion ?? record.codexVersion
        updated.bridgeVersion = event.bridgeVersion ?? Self.bridgeCapabilityVersion
        let at = event.observedAt ?? Date()

        switch event.name {
        case .toolsBridged:
            return nil

        case .toolRestored:
            guard record.status != .validated, record.status != .incompatible else {
                updated.lastObservedAt = at
                return updated == record ? nil : updated
            }
            updated.status = .observed
            updated.lastObservedAt = at
            updated.reason = nil
            return updated

        case .toolResult:
            guard record.status != .validated, record.status != .incompatible else { return nil }
            updated.status = .observed
            updated.lastObservedAt = at
            return updated

        case .childThread:
            // The strongest evidence available: a real sub-agent exists.
            updated.status = .validated
            updated.validatedAt = at
            updated.lastObservedAt = at
            updated.reason = nil
            return updated

        case .upstreamError:
            // 401/402/429/5xx/timeout say nothing about the model's ability.
            updated.lastObservedAt = at
            updated.reason = event.reason
            if record.status.isConclusion || record.status == .observed {
                return updated
            }
            updated.status = .inconclusive
            return updated

        case .incompatible:
            updated.status = .incompatible
            updated.lastObservedAt = at
            updated.reason = event.reason
            return updated
        }
    }

    /// A conclusion recorded under an older bridge contract is no longer
    /// trustworthy. It becomes `stale`; nothing is launched to re-check it.
    static func staling(
        _ record: MultiAgentCapabilityRecord,
        currentBridgeVersion: Int = MultiAgentCapabilityStore.bridgeCapabilityVersion
    ) -> MultiAgentCapabilityRecord {
        guard record.status.isConclusion,
              let observed = record.bridgeVersion,
              observed < currentBridgeVersion else { return record }
        var updated = record
        updated.status = .stale
        return updated
    }

    /// Worth telling the journal about: a status moved, or new information
    /// arrived for an existing one (typically a reason for a failed attempt).
    static func isReportable(previous: MultiAgentCapabilityRecord,
                             updated: MultiAgentCapabilityRecord) -> Bool {
        previous.status != updated.status || previous.reason != updated.reason
    }
}

/// Best-effort `codex --version`, used only to stamp an observation with the
/// Codex that produced it. Cached by the caller: never run per tool call.
public enum CodexVersionProbe {
    /// Parses `codex --version` (`codex-cli 0.154.0-alpha.6.2`). Returns nil
    /// when Codex cannot be run, which is never fatal for an observation.
    public static func version(of executable: URL, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // "codex-cli 0.154.0-alpha.6.2" -> "0.154.0-alpha.6.2"
        return text
            .split(separator: "\n")
            .first?
            .split(separator: " ")
            .last
            .map(String.init)
    }
}
