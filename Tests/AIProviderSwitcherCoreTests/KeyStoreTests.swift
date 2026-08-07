import XCTest
@testable import AIProviderSwitcherCore

final class KeyStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        SecretRegistry.shared.unregisterAll()
        super.tearDown()
    }

    func testSessionSetAndClear() {
        let store = KeyStore()
        store.setKey("sk-1234567890", for: "deepseek")
        XCTAssertTrue(store.hasKey("deepseek"))
        XCTAssertEqual(store.secret(for: "deepseek")?.asString(), "sk-1234567890")
        XCTAssertEqual(SecretRegistry.shared.count, 1)
        store.clear(providerID: "deepseek")
        XCTAssertFalse(store.hasKey("deepseek"))
        XCTAssertEqual(SecretRegistry.shared.count, 0)
    }

    func testClearAllWipesAndUnregisters() {
        let store = KeyStore()
        store.setKey("sk-aaaaaaaaaa", for: "openai")
        store.setKey("sk-bbbbbbbbbb", for: "deepseek")
        XCTAssertEqual(SecretRegistry.shared.count, 2)
        store.clearAll()
        XCTAssertEqual(SecretRegistry.shared.count, 0)
        XCTAssertFalse(store.hasKey("openai"))
        XCTAssertFalse(store.hasKey("deepseek"))
    }

    func testFilePersistenceHasMode0600() throws {
        let store = KeyStore()
        let fileURL = tempDir.appendingPathComponent("providers.json")
        try store.enablePersistence(at: fileURL)
        store.setKey("sk-persisted-XYZ123", for: "deepseek")
        store.flushToDisk(catalog: .default)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        XCTAssertEqual(String(perms, radix: 8), "600", "expected 0600, got 0o\(String(perms, radix: 8))")

        let isExcluded = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertTrue(isExcluded == true, "persistent file must be excluded from iCloud/backup")
    }

    func testLocalFileContainsKeyButExportedProfilesDoNot() throws {
        let store = KeyStore()
        let fileURL = tempDir.appendingPathComponent("providers.json")
        try store.enablePersistence(at: fileURL)
        let key = "sk-never-export-987654"
        store.setKey(key, for: "deepseek")
        store.flushToDisk(catalog: .default)

        // The explicit local store DOES contain the key (by design).
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(key), "local persistence file should contain the key")

        // Exported profiles must NOT contain the key.
        let profiles = store.exportProfiles(catalog: .default)
        let exportedJSON = String(data: try JSONEncoder().encode(profiles), encoding: .utf8) ?? ""
        XCTAssertFalse(exportedJSON.contains(key), "exported profile leaked the key: \(exportedJSON)")
        XCTAssertFalse(exportedJSON.lowercased().contains("api_key"), "exported profile has api_key field: \(exportedJSON)")
        XCTAssertFalse(exportedJSON.lowercased().contains("apikey"), "exported profile has apikey field: \(exportedJSON)")
        XCTAssertFalse(exportedJSON.lowercased().contains("secret"), "exported profile mentions secret: \(exportedJSON)")
    }

    func testLoadFromDiskRoundTrip() throws {
        let store = KeyStore()
        let fileURL = tempDir.appendingPathComponent("providers.json")
        try store.enablePersistence(at: fileURL)
        store.setKey("sk-roundtrip-AAA111", for: "openai")
        store.flushToDisk(catalog: .default)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("sk-roundtrip-AAA111"), "file did not persist key; content was: \(onDisk)")

        // Localize: can we decode the file at all?
        let raw = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([KeyStore.PersistentEntry].self, from: raw)
        XCTAssertEqual(decoded.count, 1, "expected 1 entry, got \(decoded) from content: \(onDisk)")

        let store2 = KeyStore()
        try store2.enablePersistence(at: fileURL)
        try store2.loadFromDisk()
        XCTAssertEqual(store2.secret(for: "openai")?.asString(), "sk-roundtrip-AAA111")
        XCTAssertTrue(store2.hasKey("openai"))
    }

    func testClearRewritesFileWithoutKey() throws {
        let store = KeyStore()
        let fileURL = tempDir.appendingPathComponent("providers.json")
        try store.enablePersistence(at: fileURL)
        let key = "sk-removed-222333"
        store.setKey(key, for: "deepseek")
        store.flushToDisk(catalog: .default)
        store.clear(providerID: "deepseek")

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(key), "key remained in file after clear")
    }
}
