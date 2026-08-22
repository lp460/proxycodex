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
        case "opencode": return 18892
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
        // Third-party endpoints must not be forced through Codex's native
        // ChatGPT/OAuth authentication flow. The key, when required, comes
        // from env_key; local/keyless providers simply ignore this setting.
        lines.append("requires_openai_auth = false")
        lines.append("wire_api = \(toml(provider.wireAPI.rawValue))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reasoning levels every provider understands. Codex forwards the selected
    /// effort verbatim, and OpenAI-only levels (`xhigh`, `max`, `ultra`) make a
    /// third-party endpoint reject the whole request.
    static var portableReasoningLevels: [[String: Any]] {
        [
            ["effort": "low", "description": "Fast responses with lighter reasoning"],
            ["effort": "medium", "description": "Balances speed and reasoning depth"],
            ["effort": "high", "description": "Greater reasoning depth for complex problems"]
        ]
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
        var nativeEntries: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cached = obj["models"] as? [[String: Any]], !cached.isEmpty {
            template = removingJSONNulls(cached[0]) as? [String: Any]
            for entry in cached {
                guard let slug = entry["slug"] as? String,
                      let clean = removingJSONNulls(entry) as? [String: Any] else { continue }
                nativeEntries[slug] = clean
            }
        }
        let fallback: [String: Any] = [
            "slug": "x", "display_name": "X", "description": "",
            "default_reasoning_level": "low",
            "supported_reasoning_levels": [["effort": "low", "description": ""]],
            "shell_type": "shell_command", "visibility": "list",
            "supported_in_api": true, "priority": 1,
            "apply_patch_tool_type": NSNull(),
            "web_search_tool_type": NSNull(),
            "supports_parallel_tool_calls": false,
            "supports_search_tool": false,
            "tool_mode": NSNull(),
            "input_modalities": ["text"],
            "supports_image_detail_original": false,
            "truncation_policy": ["mode": "tokens", "limit": 10000],
            "experimental_supported_tools": [],
            "use_responses_lite": false,
            "include_plugin_usage_instructions": true,
            "include_apps_usage_instructions": true,
            "include_skills_usage_instructions": true
        ]
        let tpl = template ?? fallback
        guard let provider = providers.first(where: { $0.id == activeProviderID }),
              !provider.isReserved || provider.id == "ollama" else {
            return "{\"models\": []}"
        }
        if ModelMasquerade.masquerades(provider) {
            return masqueradeCatalogJSON(provider: provider, nativeEntries: nativeEntries, cacheURL: cacheURL)
        }
        var priority = 50
        for model in provider.models {
            var e = tpl
            e["slug"] = model
            e["display_name"] = "\(provider.displayName) · \(model)"
            e["description"] = "\(provider.displayName) model \(model)."
            e["priority"] = priority
            // Advertise the capabilities declared by this provider, in the tool
            // flavor it can actually honor: `freeform` apply_patch, `local_shell`
            // and `code_mode_only` are OpenAI-only wire contracts, so every other
            // provider gets the portable `function` flavor, which the adapter
            // bridges to (and restores from) the model's function calls.
            let nativeFlavor = provider.supportsCustomTools
            e["apply_patch_tool_type"] = provider.supportsApplyPatch
                ? (nativeFlavor ? "freeform" : "function")
                : NSNull()
            e["shell_type"] = "shell_command"
            e["web_search_tool_type"] = provider.supportsWebSearch ? "text_and_image" : NSNull()
            e["supports_parallel_tool_calls"] = provider.supportsParallelToolCalls
            e["supports_search_tool"] = provider.supportsWebSearch
            e["tool_mode"] = (provider.supportsApplyPatch && nativeFlavor) ? "code_mode_only" : NSNull()
            e["input_modalities"] = provider.supportsImages ? ["text", "image"] : ["text"]
            e["supports_image_detail_original"] = provider.supportsImages
            e["truncation_policy"] = ["mode": "tokens", "limit": 10000]
            e["experimental_supported_tools"] = []
            e["use_responses_lite"] = false
            // Plugins, MCP servers, apps and skills are executed by Codex itself,
            // so their usage instructions must be sent to every provider.
            e["include_plugin_usage_instructions"] = true
            e["include_apps_usage_instructions"] = true
            e["include_skills_usage_instructions"] = true
            // Multi-agent delegation and priority tiers are OpenAI-account
            // features; a copied template must not advertise them.
            if !nativeFlavor {
                e["multi_agent_version"] = NSNull()
                e["additional_speed_tiers"] = []
                e["service_tiers"] = []
                // Codex sends `reasoning.effort` verbatim: keep only the levels
                // every provider accepts.
                e["supported_reasoning_levels"] = portableReasoningLevels
                e["default_reasoning_level"] = "medium"
            }
            priority += 1
            models.append(e)
        }
        let out: [String: Any] = ["models": models]
        let cleanOutput = removingJSONNulls(out) as? [String: Any] ?? ["models": []]
        let data = try? JSONSerialization.data(withJSONObject: cleanOutput, options: [.prettyPrinted])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"models\": []}"
    }

    /// Catalog for a provider that masquerades as Codex's own models: one entry
    /// per native slug, carrying the metadata Codex itself fetched for that slug.
    /// Codex therefore applies its full native feature contract — tools, MCP,
    /// plugins, apps, skills — while the adapter proxy swaps the model name on
    /// the wire (see `ModelMasquerade`).
    private static func masqueradeCatalogJSON(
        provider: Provider,
        nativeEntries: [String: [String: Any]],
        cacheURL: URL
    ) -> String {
        var models: [[String: Any]] = []
        var priority = 1
        for alias in ModelMasquerade.aliases(for: provider, cacheURL: cacheURL) {
            var entry = nativeEntries[alias.slug] ?? syntheticNativeEntry(slug: alias.slug, provider: provider)
            let nativeName = entry["display_name"] as? String ?? alias.slug
            entry["slug"] = alias.slug
            // The slug is what Codex checks; the display name is only shown to
            // the user, so it keeps naming the provider actually answering.
            entry["display_name"] = "\(nativeName) · \(provider.displayName)"
            entry["description"] = "\(provider.displayName) · \(alias.model), via AI Provider Switcher."
            entry["visibility"] = alias.listed ? "list" : "hide"
            entry["priority"] = priority
            // Two native switches are deliberately not inherited:
            // `use_responses_lite` is an OpenAI-internal wire shape the adapters
            // do not translate, and `code_mode_only` would replace the classic
            // tool set (shell, apply_patch, MCP function tools) with a single
            // freeform code tool — the opposite of the parity we want.
            entry["use_responses_lite"] = false
            entry.removeValue(forKey: "tool_mode")
            // Capability fields stay truthful: a hosted web search the provider
            // cannot run would be advertised, sent, then dropped by the adapter.
            if provider.supportsWebSearch {
                entry["web_search_tool_type"] = "text_and_image"
            } else {
                entry.removeValue(forKey: "web_search_tool_type")
            }
            entry["supports_search_tool"] = provider.supportsWebSearch
            entry["input_modalities"] = provider.supportsImages ? ["text", "image"] : ["text"]
            entry["supports_image_detail_original"] = provider.supportsImages
            entry["supports_parallel_tool_calls"] = provider.supportsParallelToolCalls
            if provider.supportsApplyPatch {
                // Freeform is the native flavor; the adapter bridges it to a
                // function tool and restores the `custom_tool_call` item.
                entry["apply_patch_tool_type"] = "freeform"
            } else {
                entry.removeValue(forKey: "apply_patch_tool_type")
            }
            priority += 1
            models.append(entry)
        }
        let clean = removingJSONNulls(["models": models]) as? [String: Any] ?? ["models": []]
        let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"models\": []}"
    }

    /// Native-looking entry for a slug absent from `models_cache.json` (the cache
    /// may be missing, or a provider may expose more models than it has slugs).
    private static func syntheticNativeEntry(slug: String, provider: Provider) -> [String: Any] {
        [
            "slug": slug,
            "display_name": slug,
            "description": "",
            "default_reasoning_level": "medium",
            "supported_reasoning_levels": portableReasoningLevels,
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 50,
            "additional_speed_tiers": [],
            "service_tiers": [],
            "truncation_policy": ["mode": "tokens", "limit": 10000],
            "experimental_supported_tools": [],
            "include_plugin_usage_instructions": true,
            "include_apps_usage_instructions": true,
            "include_skills_usage_instructions": true
        ]
    }

    /// Removes JSON nulls because Codex's model catalog schema rejects null for
    /// fields that are otherwise strings or maps. Unsupported optional fields
    /// must be omitted rather than represented as `null`.
    private static func removingJSONNulls(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if let clean = removingJSONNulls(child) {
                    result[key] = clean
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.compactMap(removingJSONNulls)
        }
        return value
    }

    /// Returns true when a catalog has the exact shape previously emitted by
    /// this app. This is used only to migrate legacy catalogs that predate the
    /// ownership marker; arbitrary user catalogs must remain untouched.
    public static func isGeneratedCatalog(_ data: Data, providers: [Provider]) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              !models.isEmpty else { return false }

        // Legacy catalogs copied the Codex cache template and rewrote these
        // fields for every entry. Require an exact match to a known provider's
        // complete model list; a partial or custom user catalog is not ours.
        return providers.contains { provider in
            guard !provider.models.isEmpty, models.count == provider.models.count else { return false }
            return zip(models, provider.models).allSatisfy { entry, slug in
                entry["slug"] as? String == slug
                    && entry["display_name"] as? String == "\(provider.displayName) · \(slug)"
                    && entry["description"] as? String == "\(provider.displayName) model \(slug)."
                    && entry["visibility"] as? String == "list"
                    && entry["supported_in_api"] as? Bool == true
            }
        }
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
