import Foundation

/// Generates **key-less, proxy-free** TOML snippets for the native Codex config:
/// - a provider declaration block (`[model_providers.<id>]`) appended additively;
/// - a profile file (`~/.codex/<id>.config.toml`) selected via `codex --profile <id>`.
///
/// `openai`, `ollama` and `lmstudio` are **reserved built-in** provider ids in
/// Codex and are never declared here.
public enum CodexConfigGenerator {

    /// Provider ids Codex reserves as built-ins (must NOT be redeclared).
    public static let reservedProviderIDs: Set<String> = ["openai", "ollama", "lmstudio"]

    /// Local adapter ports per third-party provider (see Resources/provider-proxy.py).
    /// Codex Desktop only lists models returned by the provider's /models
    /// endpoint, and rejects OpenAI-format responses; the proxy translates.
    public static func proxyPort(for providerID: String) -> Int? {
        switch providerID {
        case "deepseek": return 18888
        case "glm": return 18889
        case "openrouter": return 18890
        case "claude": return 18891
        default: return nil
        }
    }

    /// TOML block declaring a custom model_provider. Contains NO key: the key is
    /// read at runtime from the env var named by `env_key`. Third-party
    /// providers (those with an adapter port) route through the local proxy so
    /// Codex Desktop can list their models.
    public static func providerBlock(_ provider: Provider) -> String {
        precondition(!reservedProviderIDs.contains(provider.id), "Cannot declare reserved provider: \(provider.id)")
        var lines: [String] = []
        lines.append("[model_providers.\(provider.id)]")
        lines.append("name = \(toml(provider.displayName))")
        if let port = proxyPort(for: provider.id) {
            lines.append("base_url = \(toml("http://127.0.0.1:\(port)/v1"))")
        } else {
            lines.append("base_url = \(toml(provider.baseURL.absoluteString))")
        }
        if provider.requiresKey && !provider.environmentVariable.isEmpty {
            lines.append("env_key = \(toml(provider.environmentVariable))")
        }
        lines.append("wire_api = \(toml(provider.wireAPI.rawValue))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON model catalog for Codex Desktop (`model_catalog_json`). Contains
    /// ONLY the ACTIVE provider's models, so the Desktop picker stays clean:
    /// DeepSeek → deepseek models only; OpenAI → catalog removed (pure native).
    /// The entry template comes from the models Codex already fetched
    /// (models_cache.json), whose schema is guaranteed to parse.
    public static func catalogJSON(
        providers: [Provider],
        activeProviderID: String,
        cacheURL: URL
    ) -> String {
        var models: [[String: Any]] = []
        var template: [String: Any]?
        if let data = try? Data(contentsOf: cacheURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cached = obj["models"] as? [[String: Any]], !cached.isEmpty {
            template = cached[0]
        }
        let fallback: [String: Any] = [
            "slug": "x", "display_name": "X", "description": "",
            "default_reasoning_level": "low",
            "supported_reasoning_levels": [["effort": "low", "description": ""]],
            "shell_type": "shell_command", "visibility": "list",
            "supported_in_api": true, "priority": 1
        ]
        let tpl = template ?? fallback
        guard let provider = providers.first(where: { $0.id == activeProviderID }),
              !provider.isReserved || provider.id == "ollama" else {
            return "{\"models\": []}"
        }
        var priority = 50
        for model in provider.models {
            var e = tpl
            e["slug"] = model
            e["display_name"] = "\(provider.displayName) · \(model)"
            e["description"] = "\(provider.displayName) model \(model)."
            e["priority"] = priority
            priority += 1
            models.append(e)
        }
        let out: [String: Any] = ["models": models]
        let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"models\": []}"
    }

    /// Content of a profile file (`$CODEX_HOME/<id>.config.toml`) that selects a
    /// model + provider. Selected at launch with `codex --profile <id>`.
    public static func profileFile(model: String, providerID: String) -> String {
        """
        # Managed by AI Provider Switcher. Contains NO API keys.
        # The key (if any) is injected via the env variable named by env_key.
        model = \(toml(model))
        model_provider = \(toml(providerID))

        """
    }

    /// Safety net: true if the TOML contains an inline secret assignment or a
    /// Bearer/Authorization token. The substring `api_key` inside an env-var
    /// *name* (e.g. `DEEPSEEK_API_KEY`) is NOT flagged.
    public static func containsKeyLikeField(_ toml: String) -> Bool {
        let nsstring = toml as NSString
        if let assignment = try? NSRegularExpression(pattern: #"(?i)(api_key|apikey|secret_key)\s*[=:]"#) {
            let range = NSRange(location: 0, length: nsstring.length)
            if assignment.firstMatch(in: toml, range: range) != nil { return true }
        }
        let lowered = toml.lowercased()
        return lowered.contains("bearer ") || lowered.contains("authorization")
    }

    private static func toml(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

extension Provider {
    /// True for Codex built-in providers that must NOT be redeclared.
    public var isReserved: Bool { CodexConfigGenerator.reservedProviderIDs.contains(id) }
}
