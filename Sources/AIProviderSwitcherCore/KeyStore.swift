import Foundation

/// Stores API keys. Two modes (see spec):
///
/// - **Session** (default, recommended): keys live only in memory, are wiped on
///   clear / app exit / profile deactivation.
/// - **Local file** (opt-in, less secure): keys are written to a dedicated file
///   with Unix permissions `0600`, owned by the user, excluded from iCloud and
///   Time Machine backup.
///
/// Implements `KeyResolver` so the router/proxy can resolve the active key.
///
/// Exported *profiles* never include the key (see `exportProfile(for:)`).
public final class KeyStore: KeyResolver, @unchecked Sendable {
    /// Local persistent entry (contains the secret; written only to the 0600 file).
    public struct PersistentEntry: Codable, Equatable {
        public let providerID: String
        public let key: String
        public let baseURL: String
        public let model: String
    }

    /// Profile exported/shared by the user. Contains NO secret.
    public struct ExportedProfile: Codable, Equatable, Sendable {
        public let providerID: String
        public let displayName: String
        public let baseURL: String
        public let model: String
        public let wireAPI: String
        public let requiresKey: Bool
    }

    public enum KeyStoreError: Error, LocalizedError {
        case persistenceDisabled
        case unsupportedPlatform
        public var errorDescription: String? {
            switch self {
            case .persistenceDisabled: return "File persistence is not enabled"
            case .unsupportedPlatform: return "File persistence requires a POSIX filesystem"
            }
        }
    }

    private let lock = NSLock()
    private var memory: [String: Secret] = [:]
    private var persistenceURL: URL?
    public private(set) var persistenceEnabled: Bool = false

    public init() {}

    // MARK: - KeyResolver

    public func secret(for providerID: String) -> Secret? {
        lock.lock(); defer { lock.unlock() }
        return memory[providerID]
    }

    // MARK: - Session keys (memory only)

    /// Loads a key into memory for this session. Replaces any existing key.
    public func setKey(_ value: String, for providerID: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(providerID: providerID); return }
        let new = Secret(trimmed)
        SecretRegistry.shared.register(new)
        var previous: Secret?
        lock.lock()
        previous = memory[providerID]
        memory[providerID] = new
        lock.unlock()
        if let previous { SecretRegistry.shared.unregister(previous) }
        Log.info("Key loaded into memory for provider '\(providerID)' (len=\(new.length))")
        writeToDiskIfNeeded()
    }

    /// Whether a key is currently resident for the provider.
    public func hasKey(_ providerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return memory[providerID] != nil
    }

    public var providerIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(memory.keys)
    }

    /// Clears and wipes the key for a single provider. Also removes it from the
    /// persistent file when persistence is enabled.
    public func clear(providerID: String) {
        let removed: Secret?
        lock.lock()
        removed = memory.removeValue(forKey: providerID)
        lock.unlock()
        if let removed { SecretRegistry.shared.unregister(removed) }
        Log.info("Key cleared and wiped for provider '\(providerID)'")
        writeToDiskIfNeeded()
    }

    /// Clears and wipes all resident keys.
    public func clearAll() {
        var removed: [Secret] = []
        lock.lock()
        removed = Array(memory.values)
        memory.removeAll()
        lock.unlock()
        for s in removed { SecretRegistry.shared.unregister(s) }
        Log.info("All session keys cleared and wiped (\(removed.count))")
        writeToDiskIfNeeded()
    }

    // MARK: - Optional local file persistence (0600, no iCloud)

    /// Enables write-through persistence to a file with permissions `0600`,
    /// owned by the current user, excluded from iCloud/backup.
    @discardableResult
    public func enablePersistence(at url: URL) throws -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Create empty file with 0600 before writing anything.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        try applyRestrictivePermissions(at: url)
        lock.lock()
        persistenceURL = url
        persistenceEnabled = true
        lock.unlock()
        Log.info("Local key persistence enabled at \(url.path) (mode 0600, excluded from iCloud)")
        // NOTE: we intentionally do NOT write-through here. A freshly enabled
        // store has no in-memory keys; writing would clobber an existing file
        // before loadFromDisk() can read it. Keys are persisted via setKey/clear.
        return url
    }

    public func disablePersistence() {
        lock.lock()
        persistenceURL = nil
        persistenceEnabled = false
        lock.unlock()
        Log.info("Local key persistence disabled (in-memory keys retained until cleared)")
    }

    /// Convenience: default path under Application Support.
    public static func defaultPersistentURL(appName: String = "AI Provider Switcher") -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
            .appendingPathComponent("providers.json", isDirectory: false)
    }

    /// Loads keys from the persistent file into memory (registers + redacts them).
    public func loadFromDisk() throws {
        guard let url = currentPersistenceURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        let entries = try JSONDecoder().decode([PersistentEntry].self, from: data)
        for entry in entries {
            setKey(entry.key, for: entry.providerID)
        }
        Log.info("Loaded \(entries.count) key(s) from persistent file")
    }

    /// Provider ids that have a key in the persistent file, without exposing
    /// any secret. Used to explain why a key is not resident in memory.
    public func persistedProviderIDs() -> [String] {
        guard let url = currentPersistenceURL(), FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([PersistentEntry].self, from: data) else {
            return []
        }
        return entries.map(\.providerID)
    }

    /// Returns exported profiles for all known providers that currently have a key.
    /// **Never** contains the secret material.
    public func exportProfiles(catalog: ProviderCatalog) -> [ExportedProfile] {
        let ids = providerIDs
        return catalog.providers.compactMap { p in
            guard ids.contains(p.id) else { return nil }
            return ExportedProfile(
                providerID: p.id,
                displayName: p.displayName,
                baseURL: p.baseURL.absoluteString,
                model: p.defaultModel,
                wireAPI: p.wireAPI.rawValue,
                requiresKey: p.requiresKey
            )
        }
    }

    // MARK: - Internals

    private func currentPersistenceURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return persistenceURL
    }

    private func isPersistenceEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return persistenceEnabled
    }

    private func snapshotEntries(catalog: ProviderCatalog?) -> [PersistentEntry] {
        lock.lock(); defer { lock.unlock() }
        return memory.map { (id, secret) in
            PersistentEntry(
                providerID: id,
                key: secret.asString() ?? "",
                baseURL: catalog?[id: id]?.baseURL.absoluteString ?? "",
                model: catalog?[id: id]?.defaultModel ?? ""
            )
        }
    }

    private func writeToDiskIfNeeded(catalog: ProviderCatalog? = nil) {
        guard let url = currentPersistenceURL(), isPersistenceEnabled() else { return }
        let entries = snapshotEntries(catalog: catalog)
        do {
            let json = try JSONEncoder().encode(entries)
            try json.write(to: url, options: [.atomic])
            try? applyRestrictivePermissions(at: url)
        } catch {
            Log.error("Failed to persist keys: \(error.localizedDescription)")
        }
    }

    /// Forces a write using the given catalog for baseURL/model enrichment.
    public func flushToDisk(catalog: ProviderCatalog) {
        writeToDiskIfNeeded(catalog: catalog)
    }

    private func applyRestrictivePermissions(at url: URL) throws {
        let fm = FileManager.default
        // File: 0600 (read/write owner only).
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        // Parent directory: 0700 (rwx owner only; needs execute bit to access).
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.deletingLastPathComponent().path)
        // Exclude from iCloud backup and Time Machine.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}
