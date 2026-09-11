import XCTest
@testable import AIProviderSwitcherCore

final class OpenCodeCLITests: XCTestCase {

    func testCandidatePathsCoverOpenCodeInstallers() {
        let paths = OpenCodeCLI.candidatePaths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The official install script drops the binary in ~/.opencode/bin.
        XCTAssertEqual(paths.first, home + "/.opencode/bin/opencode")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/opencode"))
        XCTAssertTrue(paths.contains("/usr/local/bin/opencode"))
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("/opencode") })
    }

    func testCredentialsPathIsOpenCodeOwnStore() {
        XCTAssertTrue(OpenCodeCLI.credentialsURL.path
            .hasSuffix("/.local/share/opencode/auth.json"))
    }

    /// Detection must be a plain absent/present answer, never a crash, on a
    /// machine without OpenCode.
    func testDetectionIsConsistentWithTheExecutableLookup() {
        let executable = OpenCodeCLI.executableURL()
        let installation = OpenCodeCLI.detect()
        XCTAssertEqual(executable?.path, installation?.executable.path)
        if let executable {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        } else {
            XCTAssertNil(installation)
        }
    }

    func testStoredKeyReadsOpenCodeCredentialsWithProviderMapping() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload: [String: Any] = [
            "openrouter": ["type": "api", "key": "sk-or-v1-test"],
            "deepseek": ["key": "sk-deepseek-test"],
            "zai-coding-plan": ["key": "zai-id.secret"],
            "opencode": "zen-key",
            "unrelated": ["key": "nope"]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        XCTAssertEqual(OpenCodeCLI.storedKey(for: "openrouter", at: url), "sk-or-v1-test")
        XCTAssertEqual(OpenCodeCLI.storedKey(for: "deepseek", at: url), "sk-deepseek-test")
        // The app's `glm` provider is Z.ai's coding plan in the CLI.
        XCTAssertEqual(OpenCodeCLI.openCodeProviderID(for: "glm"), "zai-coding-plan")
        XCTAssertEqual(OpenCodeCLI.storedKey(for: "glm", at: url), "zai-id.secret")
        XCTAssertEqual(OpenCodeCLI.storedKey(for: "opencode", at: url), "zen-key")
        XCTAssertNil(OpenCodeCLI.storedKey(for: "ollama", at: url))
    }

    func testAuthenticatedProviderIDsNeverLeakSecrets() {
        // Only key names are surfaced; values stay in the file.
        for id in OpenCodeCLI.authenticatedProviderIDs() {
            XCTAssertFalse(id.contains("sk-"), id)
            XCTAssertLessThan(id.count, 64, id)
        }
        XCTAssertEqual(OpenCodeCLI.hasZenCredential(),
                       OpenCodeCLI.authenticatedProviderIDs().contains("opencode"))
    }
}
