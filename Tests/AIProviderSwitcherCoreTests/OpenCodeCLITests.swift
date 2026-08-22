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
