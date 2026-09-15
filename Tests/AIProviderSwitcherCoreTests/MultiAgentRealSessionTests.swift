import XCTest
@testable import AIProviderSwitcherCore

/// Replays lines captured from a real `codex exec` session (Codex
/// 0.154.0-alpha.6.2) routed through `provider-proxy.py` to GLM `glm-5.3`.
/// The excerpts below are copied verbatim from the proxy's observation log:
/// they pin the wire shape the Swift side must keep understanding, and they
/// show that a genuine sub-agent cycle lands on `validated`.
final class MultiAgentRealSessionTests: XCTestCase {
    /// First turn: the namespace reaches the provider, the provider really
    /// calls `collaboration.spawn_agent`, Codex executes it, a child thread
    /// exists, and the parent collects the result through `wait_agent`.
    private let capture = [
        #"{"event":"multi_agent_tools_bridged","provider":"glm","bridge_version":1,"observed_at":1789392793.761611,"model":"glm-5.3","slug":"gpt-5.6-terra","namespaces":["collaboration"],"tools":["collaboration.followup_task","collaboration.interrupt_agent","collaboration.list_agents","collaboration.send_message","collaboration.spawn_agent","collaboration.wait_agent"]}"#,
        #"{"event":"multi_agent_tool_restored","provider":"glm","bridge_version":1,"observed_at":1789392799.317206,"model":"glm-5.3","slug":"gpt-5.6-terra","namespace":"collaboration","tool":"spawn_agent","call_id":"call_6b06d83c08c842549dcaac80"}"#,
        #"{"event":"multi_agent_tool_result","provider":"glm","bridge_version":1,"observed_at":1789392799.3604858,"model":"glm-5.3","slug":"gpt-5.6-terra","namespace":"collaboration","tool":"spawn_agent","call_id":"call_6b06d83c08c842549dcaac80"}"#,
        #"{"event":"multi_agent_child_thread","provider":"glm","bridge_version":1,"observed_at":1789392799.360628,"model":"glm-5.3","slug":"gpt-5.6-terra","parent_thread_id":"01a0a01f-3071-71b0-8349-1f6082403097","tools":["collaboration.spawn_agent"]}"#,
        #"{"event":"multi_agent_tool_restored","provider":"glm","bridge_version":1,"observed_at":1789392802.9058821,"model":"glm-5.3","slug":"gpt-5.6-terra","namespace":"collaboration","tool":"wait_agent","call_id":"call_3ac1090d124d4e89a8704d25"}"#,
        #"{"event":"multi_agent_tool_result","provider":"glm","bridge_version":1,"observed_at":1789392812.7254038,"model":"glm-5.3","slug":"gpt-5.6-terra","namespace":"collaboration","tool":"wait_agent","call_id":"call_3ac1090d124d4e89a8704d25"}"#,
    ]

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("real-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func events() throws -> [MultiAgentEvent] {
        try capture.map { try JSONDecoder().decode(MultiAgentEvent.self, from: Data($0.utf8)) }
    }

    func testRealCapturedSessionValidatesTheModel() async throws {
        let storeURL = directory.appendingPathComponent("model-capabilities.json")
        let store = MultiAgentCapabilityStore(url: storeURL)

        _ = await store.apply(try events(), codexVersion: "0.154.0-alpha.6.2")

        let record = await store.record(for: "glm", modelID: "glm-5.3")
        XCTAssertEqual(record?.status, .validated)
        XCTAssertEqual(record?.bridgeVersion, MultiAgentCapabilityStore.bridgeCapabilityVersion)
        XCTAssertEqual(record?.codexVersion, "0.154.0-alpha.6.2")
        XCTAssertNotNil(record?.validatedAt)

        // A model that was never used stays honestly unknown.
        let untouched = await store.record(for: "opencode-go", modelID: "grok-4.6")
        XCTAssertNil(untouched)
    }

    /// The real log carries identifiers and tool names, never prompts,
    /// arguments, tool output or secrets.
    func testRealCapturedSessionCarriesNoUserContent() throws {
        let allowed: Set<String> = [
            "event", "provider", "bridge_version", "observed_at", "model", "slug",
            "namespaces", "tools", "namespace", "tool", "call_id", "parent_thread_id",
        ]
        for line in capture {
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            for key in payload.keys {
                XCTAssertTrue(allowed.contains(key), "unexpected field in the log: \(key)")
            }
        }
        // No user text: the trivial task asked of the sub-agent never appears.
        XCTAssertFalse(capture.joined().contains("AIProviderSwitcherCore"))
    }

    /// The proxy reports the real upstream model, and the panel keys records by
    /// the same name, so the lookup the UI performs finds the record.
    func testRealCaptureKeysByProviderAndUpstreamModel() throws {
        let first = try XCTUnwrap(try events().first)
        XCTAssertEqual(first.provider, "glm")
        XCTAssertEqual(first.model, "glm-5.3")
        XCTAssertEqual(first.slug, "gpt-5.6-terra")
        XCTAssertEqual(first.modelKey?.providerID, "glm")
        XCTAssertEqual(first.modelKey?.modelID, "glm-5.3")
    }
}
