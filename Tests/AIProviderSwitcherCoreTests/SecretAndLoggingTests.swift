import XCTest
@testable import AIProviderSwitcherCore

final class SecretAndLoggingTests: XCTestCase {

    func testSecretWipe() {
        let s = Secret("sk-secret-123456")
        XCTAssertEqual(s.length, 16)
        XCTAssertEqual(s.asString(), "sk-secret-123456")
        s.wipe()
        XCTAssertEqual(s.length, 0)
        XCTAssertEqual(s.asString(), "")
    }

    func testRedactorScrubsKnownSecretFromLogs() {
        let sink = MemorySink()
        Log.sink = sink
        Log.minimumLevel = .debug

        let secret = Secret("sk-supersecret-ABCDEF")
        SecretRegistry.shared.register(secret)
        defer { SecretRegistry.shared.unregister(secret) }

        sink.clear()
        Log.info("Auth header was Bearer \(secret.asString() ?? "") at node X")
        let logged = sink.allJoined
        XCTAssertFalse(logged.contains("sk-supersecret-ABCDEF"), "raw key leaked into logs: \(logged)")
        XCTAssertTrue(logged.contains("[REDACTED]"))
    }

    func testRedactorIgnoresShortSecrets() {
        let sink = MemorySink()
        Log.sink = sink
        Log.minimumLevel = .debug
        let short = Secret("abc")
        SecretRegistry.shared.register(short)
        defer { SecretRegistry.shared.unregister(short) }
        sink.clear()
        Log.info("value abc here")
        XCTAssertTrue(sink.allJoined.contains("abc")) // too short to redact
    }

    func testRedactorHandlesAbsentSecretGracefully() {
        let sink = MemorySink()
        Log.sink = sink
        Log.minimumLevel = .debug
        sink.clear()
        Log.info("nothing secret here")
        XCTAssertEqual(sink.allJoined, "nothing secret here")
    }
}
