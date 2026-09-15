import XCTest
@testable import AIProviderSwitcherCore

final class MultiAgentCapabilityTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capabilities-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("model-capabilities.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(
        _ name: MultiAgentEvent.Name,
        provider: String = "glm",
        model: String = "glm-5.3",
        reason: String? = nil,
        bridgeVersion: Int = MultiAgentCapabilityStore.bridgeCapabilityVersion
    ) -> MultiAgentEvent {
        MultiAgentEvent(decoding: [
            "event": name.rawValue,
            "provider": provider,
            "model": model,
            "call_id": "call_1",
            "reason": reason,
            "bridge_version": bridgeVersion,
            "observed_at": 1_789_000_000.0,
        ])
    }

    // MARK: State machine

    func testPassiveLifecycleFromUnknownToValidated() async {
        let store = MultiAgentCapabilityStore(url: storeURL)

        // Nothing observed: the honest default.
        var record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertNil(record)

        // Codex exposed the namespace and the bridge forwarded it: not a verdict.
        var change = await store.apply(event(.toolsBridged))
        XCTAssertNil(change)
        record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertNil(record)

        // The provider really emitted the call, restored for Codex.
        change = await store.apply(event(.toolRestored))
        XCTAssertEqual(change?.current, .observed)
        record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .observed)
        XCTAssertNotNil(record?.lastObservedAt)

        // Codex executed it, and a real child thread appeared.
        _ = await store.apply(event(.toolResult))
        change = await store.apply(event(.childThread))
        XCTAssertEqual(change?.current, .validated)
        record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
        XCTAssertNotNil(record?.validatedAt)
        XCTAssertEqual(record?.bridgeVersion, MultiAgentCapabilityStore.bridgeCapabilityVersion)
    }

    func testModelThatNeverDelegatesStaysUnknown() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        let untouched = await store.record(for: "opencode-go", modelID: "grok-4.6")
        XCTAssertNil(untouched)
        // Only the bridge carrying the tools was seen: no conclusion either way.
        _ = await store.apply(event(.toolsBridged, provider: "opencode-go", model: "grok-4.6"))
        let stillUnknown = await store.record(for: "opencode-go", modelID: "grok-4.6")
        XCTAssertNil(stillUnknown)
    }

    func testInfrastructureFailuresNeverProduceIncompatible() async {
        for code in ["authentication_required", "insufficient_balance", "rate_limited",
                     "provider_error", "network", "timeout", "forbidden"] {
            let store = MultiAgentCapabilityStore(url: storeURL)
            let change = await store.apply(event(.upstreamError, reason: code))
            XCTAssertEqual(change?.current, .inconclusive, "code \(code)")
            let record = await store.record(for: "glm", modelID: "glm-5.3")
            XCTAssertNotEqual(record?.status, .incompatible, "code \(code)")
            XCTAssertEqual(record?.reason, code)
        }
    }

    func testTemporaryFailureNeverDowngradesAValidation() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        _ = await store.apply(event(.childThread))
        let before = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(before?.status, .validated)

        // A week later the quota runs out: the validation must survive.
        let change = await store.apply(event(.upstreamError, reason: "rate_limited"))
        // The status does not move — only the failure is remembered.
        XCTAssertEqual(change?.current, .validated)
        XCTAssertEqual(change?.previous, .validated)
        XCTAssertEqual(change?.reason, "rate_limited")
        let record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
        XCTAssertEqual(record?.reason, "rate_limited")
    }

    func testObservedAttemptSurvivesAnInfrastructureError() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        _ = await store.apply(event(.toolRestored))
        _ = await store.apply(event(.upstreamError, reason: "insufficient_balance"))
        let record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .observed)
        XCTAssertEqual(record?.reason, "insufficient_balance")
    }

    func testIncompatibleIsReservedForProtocolEvidence() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        let change = await store.apply(event(.incompatible, reason: "protocol_incompatible"))
        XCTAssertEqual(change?.current, .incompatible)
        let record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .incompatible)
    }

    /// The proxy reports `invalid_request` (400) and `unsupported_request` (422)
    /// for a gateway that refuses one item of a request. Those codes must have a
    /// label of their own: falling back to a generic "unknown cause" would hide
    /// the one piece of information the user actually needs.
    func testRefusalCodesHaveTheirOwnUserFacingReason() {
        XCTAssertEqual(MultiAgentFailureReason(code: "invalid_request").localizationKey,
                       "Requête invalide")
        XCTAssertEqual(MultiAgentFailureReason(code: "unsupported_request").localizationKey,
                       "Requête non supportée")
        XCTAssertEqual(MultiAgentFailureReason(code: "provider_protocol_error").localizationKey,
                       "Erreur de protocole fournisseur")
        // A code nobody declared stays unnamed rather than being guessed at.
        XCTAssertEqual(MultiAgentFailureReason(code: "http_409").localizationKey,
                       "Cause inconnue")
    }

    // MARK: Identity, persistence, versioning

    func testIdentityIsProviderAndModelNeverModelAlone() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        _ = await store.apply(event(.childThread, provider: "opencode-go", model: "grok-4.6"))
        _ = await store.apply(event(.upstreamError, provider: "openrouter", model: "grok-4.6",
                                    reason: "rate_limited"))
        let validated = await store.record(for: "opencode-go", modelID: "grok-4.6")
        let failed = await store.record(for: "openrouter", modelID: "grok-4.6")
        XCTAssertEqual(validated?.status, .validated)
        XCTAssertEqual(failed?.status, .inconclusive)
        let total = await store.all().count
        XCTAssertEqual(total, 2)
    }

    func testRecordsSurviveAReload() async throws {
        let first = MultiAgentCapabilityStore(url: storeURL)
        _ = await first.apply(event(.childThread), codexVersion: "0.154.0-alpha.6.2")
        try await first.save()

        let second = MultiAgentCapabilityStore(url: storeURL)
        let record = await second.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
        XCTAssertEqual(record?.codexVersion, "0.154.0-alpha.6.2")
    }

    func testOlderBridgeVersionBecomesStaleWithoutAnyNewRequest() async throws {
        let directory = self.directory!
        let url = directory.appendingPathComponent("older.json")
        let legacy = [
            ModelCapabilityRecord(
                providerID: "glm", modelID: "glm-5.3",
                multiAgent: MultiAgentCapabilityRecord(
                    status: .validated,
                    validatedAt: Date(timeIntervalSince1970: 1_789_000_000),
                    lastObservedAt: Date(timeIntervalSince1970: 1_789_000_000),
                    bridgeVersion: MultiAgentCapabilityStore.bridgeCapabilityVersion - 1))
        ]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = MultiAgentCapabilityStore(url: url)
        let record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .stale)
        // The conclusion is kept for reference; only the verdict is withdrawn.
        XCTAssertNotNil(record?.validatedAt)
        // And the downgrade is persisted, so it is not recomputed forever.
        let reloaded = MultiAgentCapabilityStore(url: url)
        let persisted = await reloaded.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(persisted?.status, .stale)
    }

    func testCurrentBridgeVersionIsNotStaled() async throws {
        let store = MultiAgentCapabilityStore(url: storeURL)
        _ = await store.apply(event(.childThread))
        let reloaded = MultiAgentCapabilityStore(url: storeURL)
        let record = await reloaded.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
    }

    func testStaleValidationIsRefreshedByTheNextRealUse() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        let stale = ModelCapabilityRecord(
            providerID: "glm", modelID: "glm-5.3",
            multiAgent: MultiAgentCapabilityRecord(status: .stale,
                                                   bridgeVersion: MultiAgentCapabilityStore.bridgeCapabilityVersion))
        try? JSONEncoder().encode([stale]).write(to: storeURL)
        _ = await store.load()
        _ = await store.apply(event(.toolRestored))
        let observed = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(observed?.status, .observed)
        _ = await store.apply(event(.childThread))
        let validated = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(validated?.status, .validated)
    }

    // MARK: Event log

    func testEventLogDrainsCompleteLinesAndKeepsPartialTail() throws {
        let logURL = directory.appendingPathComponent("multi-agent-events.jsonl")
        let complete = """
        {"event":"multi_agent_tool_restored","provider":"glm","model":"glm-5.3","call_id":"c1"}
        {"event":"multi_agent_child_thread","provider":"glm","model":"glm-5.3"}
        {"event":"multi_agent_tools_bridged","provider":"glm","model":"glm-5.3"}

        """
        try (complete + "{\"event\":\"multi_agent_tool_result\"").write(
            to: logURL, atomically: true, encoding: .utf8)

        let log = MultiAgentEventLog(url: logURL)
        let first = log.drain()
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.first?.name, .toolRestored)
        XCTAssertEqual(first.first?.callID, "c1")
        // The unfinished line stays for the next pass instead of being lost.
        let remainder = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(remainder, "{\"event\":\"multi_agent_tool_result\"")

        // Completing the line makes it readable on the next drain.
        try (remainder + "}\n").write(to: logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(log.drain().map(\.name), [.toolResult])
        XCTAssertEqual(log.currentSize(), 0)
    }

    func testEventLogIgnoresMalformedAndUnknownLines() throws {
        let logURL = directory.appendingPathComponent("multi-agent-events.jsonl")
        try """
        not json
        {"event":"some_future_event","provider":"glm","model":"glm-5.3"}
        {"event":"multi_agent_tool_restored","provider":"glm","model":"glm-5.3"}

        """.write(to: logURL, atomically: true, encoding: .utf8)
        let events = MultiAgentEventLog(url: logURL).drain()
        XCTAssertEqual(events.map(\.name), [.toolRestored])
    }

    func testMissingEventLogIsNotAnError() {
        let log = MultiAgentEventLog(url: directory.appendingPathComponent("absent.jsonl"))
        XCTAssertFalse(log.exists())
        XCTAssertEqual(log.drain(), [])
        XCTAssertEqual(log.currentSize(), 0)
    }

    // MARK: Privacy

    func testPersistedRecordsKeepNoUserContent() async throws {
        let store = MultiAgentCapabilityStore(url: storeURL)
        let eavesdropper = MultiAgentEvent(decoding: [
            "event": "multi_agent_child_thread",
            "provider": "glm",
            "model": "glm-5.3",
            "call_id": "call_1",
            "reason": "rate_limited",
        ])
        _ = await store.apply(eavesdropper, codexVersion: "0.154.0-alpha.6.2")
        try await store.save()
        let raw = try String(contentsOf: storeURL, encoding: .utf8)
        for forbidden in ["prompt", "arguments", "token", "authorization", "api_key",
                          "output", "menu", "message"] {
            XCTAssertFalse(raw.lowercased().contains(forbidden),
                           "capability file must not contain \(forbidden)")
        }
        // Only the technical identity is kept.
        XCTAssertTrue(raw.contains("glm-5.3"))
        XCTAssertTrue(raw.contains("validated"))
    }

    func testCompatibilityPathSeparatesNativeSupportFromObservation() {
        // OpenAI native: Codex supports Multi-Agent itself, but that is an
        // expectation, not an observation — so the status stays unknown.
        let native = MultiAgentCompatibility(path: .nativeCodex, record: nil)
        XCTAssertEqual(native.status, .unknown)

        // Ollama has no adapter: unknown unless a real observation exists.
        let unbridged = MultiAgentCompatibility(path: .unbridged, record: nil)
        XCTAssertEqual(unbridged.status, .unknown)

        let bridged = MultiAgentCompatibility(
            path: .bridged,
            record: MultiAgentCapabilityRecord(status: .validated))
        XCTAssertEqual(bridged.status, .validated)
    }

    /// A sub-agent that appears right before a provider failure proves a real
    /// spawn, not a completed cycle: the status must stay "observed".
    func testInterruptedCycleAfterChildThreadDoesNotValidate() async {
        let store = MultiAgentCapabilityStore(url: storeURL)
        _ = await store.apply([
            event(.toolsBridged),
            event(.toolRestored),
            event(.toolResult),
            event(.childThread),
            event(.upstreamError, reason: "http_422"),
        ])

        var record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .observed)
        XCTAssertNil(record?.validatedAt)
        XCTAssertEqual(record?.reason, "http_422")

        // A later, complete cycle validates normally.
        _ = await store.apply([
            event(.toolRestored),
            event(.toolResult),
            event(.childThread),
            event(.toolResult),
        ])
        record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
        XCTAssertNotNil(record?.validatedAt)
        XCTAssertNil(record?.reason)
    }

    /// Requirement: observing compatibility must never cost a request. The
    /// capability layer only reads the proxy's local log and writes its own
    /// JSON, so it must not grow any networking symbol.
    func testCapabilityLayerPerformsNoNetworkIO() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AIProviderSwitcherCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/AIProviderSwitcherCore/MultiAgentCapability.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["URLSession", "URLRequest", "URLProtocol", "NWConnection",
                          "Network.framework", "async let", "http://", "https://"] {
            XCTAssertFalse(text.contains(forbidden),
                           "capability layer must not use \(forbidden)")
        }
    }
}

private extension MultiAgentEvent {
    /// Test helper: build an event from the wire shape the proxy writes.
    init(decoding payload: [String: Any]) {
        var normalized = payload
        if normalized["observed_at"] == nil {
            normalized["observed_at"] = Date().timeIntervalSince1970
        }
        if normalized["bridge_version"] == nil {
            normalized["bridge_version"] = MultiAgentCapabilityStore.bridgeCapabilityVersion
        }
        let data = try! JSONSerialization.data(withJSONObject: normalized)
        self = try! JSONDecoder().decode(MultiAgentEvent.self, from: data)
    }
}
