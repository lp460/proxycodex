import Foundation

/// A byte buffer holding a secret (API key). Best-effort wipeable.
///
/// `Secret` is used so that:
/// - the raw key string is not stored as an ordinary `String` longer than necessary;
/// - it can be explicitly wiped from memory on session close;
/// - the redactor can scrub it from any log line before it reaches a sink.
///
/// Notes on the threat model: complete guarantees about wiping are not possible
/// in a garbage-collected/high-level language runtime. This class does best-effort
/// zeroing. The hard guarantees required by the spec (key never in `config.toml`,
/// never in process arguments, never in logs, never in the process list) are
/// enforced elsewhere and do not depend on zeroing.
public final class Secret: @unchecked Sendable {
    private var bytes: [UInt8]
    private let lock = NSLock()

    public init(_ value: String) {
        self.bytes = Array(value.utf8)
    }

    public init?(hexOrRaw value: String) {
        guard !value.isEmpty else { return nil }
        self.bytes = Array(value.utf8)
    }

    public var length: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
    }

    public var isEmpty: Bool { length == 0 }

    /// Returns a transient UTF8 string. The returned value is an immutable copy;
    /// callers should not retain it.
    public func asString() -> String? {
        lock.lock(); defer { lock.unlock() }
        return String(bytes: bytes, encoding: .utf8)
    }

    public func withBytes<R>(_ body: ([UInt8]) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(bytes)
    }

    /// Overwrites the buffer with zeros and drops capacity.
    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        for i in bytes.indices { bytes[i] = 0 }
        bytes.removeAll(keepingCapacity: false)
    }

    deinit {
        for i in bytes.indices { bytes[i] = 0 }
    }
}

extension Secret: Hashable {
    public static func == (lhs: Secret, rhs: Secret) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
