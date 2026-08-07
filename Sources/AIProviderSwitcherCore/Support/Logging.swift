import Foundation
#if canImport(os)
import os
#endif

public enum LogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A sink receives already-redacted messages only. Sinks must never see raw
/// secrets, therefore `Log` always routes through `SecretRegistry.redact` first.
public protocol LogSink: Sendable {
    func write(_ level: LogLevel, _ message: String, file: String, line: Int)
}

/// Default sink backed by the unified logging system (`os.Logger`).
public struct OSLogSink: LogSink {
    private let logger: Logger
    public init(subsystem: String = "ai.proxyswitcher.app") {
        self.logger = Logger(subsystem: subsystem, category: "core")
    }
    public func write(_ level: LogLevel, _ message: String, file: String, line: Int) {
        // message is already redacted by `Log`, so public privacy is safe.
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)")
        }
    }
}

/// In-memory sink used by tests to assert that no raw key is ever emitted.
public final class MemorySink: LogSink, @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public let level: LogLevel
        public let message: String
        public let file: String
        public let line: Int
    }
    private let lock = NSLock()
    private var storage: [Entry] = []
    public init() {}
    public func write(_ level: LogLevel, _ message: String, file: String, line: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append(Entry(level: level, message: message, file: file, line: line))
    }
    public var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
    public var allJoined: String { entries.map(\.message).joined(separator: "\n") }
}

/// Holds references to currently-resident secrets so that any string can be
/// scrubbed before being logged. References are strong and removed explicitly
/// when a key is cleared (which also wipes the secret).
public final class SecretRegistry: @unchecked Sendable {
    public static let shared = SecretRegistry()
    private let lock = NSLock()
    private var secrets: [Secret] = []
    private init() {}

    public func register(_ secret: Secret) {
        lock.lock(); defer { lock.unlock() }
        secrets.append(secret)
    }

    public func unregister(_ secret: Secret) {
        lock.lock(); defer { lock.unlock() }
        secrets.removeAll { $0 === secret }
        secret.wipe()
    }

    public func unregisterAll() {
        lock.lock(); defer { lock.unlock() }
        for s in secrets { s.wipe() }
        secrets.removeAll()
    }

    /// Replaces any occurrence of a known secret by `[REDACTED]`.
    /// Only secrets with a minimum length are considered, to avoid clobbering
    /// common short substrings.
    public func redact(_ string: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var result = string
        for s in secrets {
            guard let plain = s.asString(), plain.count >= 6 else { continue }
            if result.range(of: plain) != nil {
                result = result.replacingOccurrences(of: plain, with: "[REDACTED]")
            }
        }
        return result
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return secrets.count
    }
}

public enum Log {
    /// Mutable so tests can install a `MemorySink`. Access is process-wide.
    nonisolated(unsafe) public static var sink: LogSink = OSLogSink()
    nonisolated(unsafe) public static var minimumLevel: LogLevel = .info

    public static func redact(_ string: String) -> String {
        SecretRegistry.shared.redact(string)
    }

    @inline(__always)
    private static func emit(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, line: Int) {
        guard level >= minimumLevel else { return }
        let redacted = SecretRegistry.shared.redact(message())
        sink.write(level, redacted, file: file, line: line)
    }

    public static func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.debug, message(), file: file, line: line)
    }
    public static func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.info, message(), file: file, line: line)
    }
    public static func warning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.warning, message(), file: file, line: line)
    }
    public static func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        emit(.error, message(), file: file, line: line)
    }
}
