import Foundation

/// Persists the per-provider subset of models the user chose to expose through
/// the finite Codex slug slots (one listed native slug per model). Contains no
/// secret material.
///
/// An absent entry means "keep the provider's first models" — the list Codex
/// exposes without any user intervention.
public struct ModelSelectionStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        KeyStore.defaultPersistentURL()
            .deletingLastPathComponent()
            .appendingPathComponent("model-selection.json")
    }

    public func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    public func save(_ entries: [String: [String]]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}
