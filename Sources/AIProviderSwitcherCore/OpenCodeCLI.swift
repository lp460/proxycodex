import Foundation

/// What was found of an OpenCode install on this machine.
public struct OpenCodeInstallation: Sendable, Equatable {
    public let executable: URL
    /// `opencode --version` output, when it could be read.
    public let version: String?
    /// True when OpenCode holds its own OpenCode Zen credential, which the
    /// adapter prefers over the public free-tier key.
    public let hasZenCredential: Bool

    public init(executable: URL, version: String?, hasZenCredential: Bool) {
        self.executable = executable
        self.version = version
        self.hasZenCredential = hasZenCredential
    }
}

/// Detects the OpenCode CLI (github.com/sst/opencode).
///
/// The CLI is an agent, not an HTTP model backend: what makes OpenCode usable as
/// a Codex provider is **OpenCode Zen**, the OpenAI-compatible gateway the CLI
/// itself talks to (`https://opencode.ai/zen/v1`, free tier under the documented
/// `public` key). The gateway works without the CLI, so detection is
/// informational — it tells the user where their models and credential come
/// from, and confirms the CLI they installed is the one being mirrored.
public enum OpenCodeCLI {

    /// Install locations, in the order OpenCode's own installer uses them.
    public static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".opencode/bin/opencode").path,
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            home.appendingPathComponent(".local/bin/opencode").path,
            "/usr/bin/opencode"
        ]
    }

    /// `~/.local/share/opencode/auth.json`, where the CLI keeps the credentials
    /// it obtained through `opencode auth login`. Only key **names** are read;
    /// the secrets stay in the file.
    public static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    /// Provider ids OpenCode is authenticated for, e.g. `["deepseek", "openrouter"]`.
    /// Never returns secret material.
    public static func authenticatedProviderIDs() -> [String] {
        guard let data = try? Data(contentsOf: credentialsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted()
    }

    public static func hasZenCredential() -> Bool {
        authenticatedProviderIDs().contains("opencode")
    }

    /// Locates the executable without running it.
    public static func executableURL() -> URL? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Full detection. Runs `opencode --version`, so call it off the main actor.
    public static func detect() -> OpenCodeInstallation? {
        guard let executable = executableURL() else { return nil }
        return OpenCodeInstallation(
            executable: executable,
            version: readVersion(of: executable),
            hasZenCredential: hasZenCredential()
        )
    }

    private static func readVersion(of executable: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = Pipe()
        // A CLI that hangs must not hold the launch path: read, then give up.
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `--version` prints just the number; keep the first token either way.
        return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
