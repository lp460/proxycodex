import Foundation

/// Model list a provider really serves, as answered by the provider itself.
public struct DiscoveredModels: Codable, Sendable, Equatable {
    public let models: [String]
    /// Where the list came from: `upstream`, `anthropic`, `gateway`,
    /// `opencode-cli`, or `ollama`.
    public let source: String
    public let fetchedAt: Date

    public init(models: [String], source: String, fetchedAt: Date) {
        self.models = models
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

/// Asks each provider what models it currently serves, so a newly released model
/// shows up without shipping a new build.
///
/// The query goes through the local adapter (`/_switcher/upstream-models`), which
/// is the only component that knows the upstream URL and how to authenticate to
/// it — the OpenCode CLI for the Zen free tier, Claude Code's own token for
/// Anthropic, the relayed key elsewhere. Providers without an adapter (Ollama)
/// are queried directly.
public struct ModelDiscovery: Sendable {
    public let client: HTTPClient
    public let timeout: TimeInterval

    /// Above this many models the provider's own list is not a usable picker
    /// (OpenRouter serves hundreds), so the curated list is kept instead.
    public static let listableLimit = 30

    public init(client: HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 25) {
        self.client = client
        self.timeout = timeout
    }

    public func discoveryURL(for provider: Provider) -> URL? {
        if let port = CodexConfigGenerator.proxyPort(for: provider.id) {
            return URL(string: "http://127.0.0.1:\(port)/_switcher/upstream-models")
        }
        guard !provider.isReserved || provider.id == "ollama" else { return nil }
        return provider.baseURL.appendingPathComponent("models")
    }

    public func discover(provider: Provider, secret: Secret?) async throws -> DiscoveredModels? {
        guard let url = discoveryURL(for: provider) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider.requiresKey, let key = secret?.asString(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (response, data) = try await client.send(request)
        guard response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let models = Self.identifiers(in: object)
        guard !models.isEmpty else { return nil }
        return DiscoveredModels(
            models: models,
            source: object["source"] as? String ?? "upstream",
            fetchedAt: Date()
        )
    }

    /// Accepts the adapter's shape (`{"models": ["id"]}`), the OpenAI shape
    /// (`{"data": [{"id": …}]}`) and the Codex catalog shape (`slug`).
    static func identifiers(in object: [String: Any]) -> [String] {
        if let plain = object["models"] as? [String] { return plain }
        let items = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
        var seen: Set<String> = []
        return items.compactMap { item in
            guard let id = (item["id"] ?? item["slug"] ?? item["name"]) as? String,
                  !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
    }

    /// Model list to declare for a provider, given what it answered.
    ///
    /// The provider's own list wins when it is small enough to be a picker; its
    /// order is kept (providers list their newest first) with the configured
    /// default hoisted, since the default takes the primary native slug.
    public static func resolvedModels(for provider: Provider, discovered: DiscoveredModels?) -> [String] {
        guard let discovered, !discovered.models.isEmpty,
              discovered.models.count <= listableLimit else { return provider.models }
        var models = discovered.models
        if let index = models.firstIndex(of: provider.defaultModel) {
            models.remove(at: index)
            models.insert(provider.defaultModel, at: 0)
        } else {
            // Keep the configured default reachable even if the provider
            // stopped listing it.
            models.insert(provider.defaultModel, at: 0)
        }
        return models
    }
}

/// Persists discovered model lists so a relaunch starts from the last known
/// state instead of the shipped defaults. Contains no secret material.
public struct DiscoveredModelStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        KeyStore.defaultPersistentURL()
            .deletingLastPathComponent()
            .appendingPathComponent("discovered-models.json")
    }

    public func load() -> [String: DiscoveredModels] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: DiscoveredModels].self, from: data)) ?? [:]
    }

    public func save(_ entries: [String: DiscoveredModels]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}
