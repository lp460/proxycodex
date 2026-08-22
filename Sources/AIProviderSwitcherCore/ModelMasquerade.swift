import Foundation

/// A model slug Codex treats as its own, as declared by the catalog Codex itself
/// fetched (`~/.codex/models_cache.json`).
public struct NativeModel: Sendable, Equatable {
    public let slug: String
    /// `visibility == "list"`: offered in the model picker. Hidden slugs
    /// (`gpt-reserve`, `codex-auto-review`) are used internally by Codex.
    public let listed: Bool

    public init(slug: String, listed: Bool) {
        self.slug = slug
        self.listed = listed
    }
}

/// Pairing between a slug Codex believes is native and the provider model that
/// really answers it. The slug travels through `config.toml` and the wire; the
/// adapter proxy swaps it for `model` before calling the provider and restores
/// it in the response.
public struct ModelAlias: Sendable, Equatable {
    public let slug: String
    public let model: String
    public let listed: Bool

    public init(slug: String, model: String, listed: Bool) {
        self.slug = slug
        self.model = model
        self.listed = listed
    }
}

/// Presents third-party models under Codex's own model slugs.
///
/// Codex gates part of its feature set on the model it thinks it is talking to:
/// a slug it does not recognize can lose tools, plugins, MCP, apps or skills
/// whatever the catalog claims. Every provider reached through a local adapter
/// therefore advertises native slugs, with the native metadata Codex fetched for
/// them, while the adapter rewrites the model name on the wire.
public enum ModelMasquerade {

    /// Only providers behind a local adapter can masquerade: something has to
    /// rewrite the model name. Codex built-ins (`openai`, `ollama`, `lmstudio`)
    /// talk to their endpoint directly, so they keep their real slugs.
    public static func masquerades(_ provider: Provider) -> Bool {
        CodexConfigGenerator.proxyPort(for: provider.id) != nil
    }

    /// Slugs used when `models_cache.json` is unreadable, and to extend the pool
    /// when a provider offers more models than the cache has slugs.
    public static var fallbackNativeModels: [NativeModel] {
        [
            NativeModel(slug: "gpt-5.6-sol", listed: true),
            NativeModel(slug: "gpt-5.6-terra", listed: true),
            NativeModel(slug: "gpt-5.6-luna", listed: true),
            NativeModel(slug: "gpt-5.6", listed: true),
            NativeModel(slug: "gpt-5.5", listed: true),
            NativeModel(slug: "gpt-5.4", listed: true),
            NativeModel(slug: "gpt-5.4-mini", listed: true),
            NativeModel(slug: "gpt-5.3-codex-spark", listed: true),
            NativeModel(slug: "gpt-reserve", listed: false),
            NativeModel(slug: "codex-auto-review", listed: false)
        ]
    }

    /// Native slugs, cache first (they carry real metadata), then the fallback
    /// pool so a provider with many models still gets one slug per model.
    public static func nativeModels(cacheURL: URL) -> [NativeModel] {
        var models: [NativeModel] = []
        var seen: Set<String> = []
        if let data = try? Data(contentsOf: cacheURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cached = object["models"] as? [[String: Any]] {
            for entry in cached {
                guard let slug = entry["slug"] as? String, !slug.isEmpty, !seen.contains(slug) else { continue }
                seen.insert(slug)
                models.append(NativeModel(slug: slug, listed: (entry["visibility"] as? String) != "hide"))
            }
        }
        for model in fallbackNativeModels where !seen.contains(model.slug) {
            seen.insert(model.slug)
            models.append(model)
        }
        return models
    }

    public static func aliases(for provider: Provider, cacheURL: URL) -> [ModelAlias] {
        aliases(for: provider, native: nativeModels(cacheURL: cacheURL))
    }

    /// Pairs each provider model with one listed native slug, in order, starting
    /// with the provider's default model so it always gets the top slug — the
    /// picker then shows exactly as many entries as the provider has models.
    /// Hidden slugs Codex uses internally (`codex-auto-review`, `gpt-reserve`)
    /// are always emitted, mapped to the default model, so those requests reach
    /// a real model too.
    public static func aliases(for provider: Provider, native: [NativeModel]) -> [ModelAlias] {
        let ordered = [provider.defaultModel] + provider.models.filter { $0 != provider.defaultModel }
        var result: [ModelAlias] = []
        var index = 0
        for slug in native where slug.listed {
            guard index < ordered.count else { break }
            result.append(ModelAlias(slug: slug.slug, model: ordered[index], listed: true))
            index += 1
        }
        for slug in native where !slug.listed {
            result.append(ModelAlias(slug: slug.slug, model: provider.defaultModel, listed: false))
        }
        return result
    }

    /// The slug Codex must see for this provider model. Returns `model` itself
    /// for providers that do not masquerade.
    public static func slug(for model: String, provider: Provider, cacheURL: URL) -> String {
        guard masquerades(provider) else { return model }
        let map = aliases(for: provider, cacheURL: cacheURL)
        return map.first { $0.model == model && $0.listed }?.slug
            ?? map.first { $0.model == model }?.slug
            ?? map.first?.slug
            ?? model
    }

    /// The provider model behind a slug. Unknown slugs fall back to the
    /// provider's default model rather than failing the request.
    public static func model(for slug: String, provider: Provider, cacheURL: URL) -> String {
        guard masquerades(provider) else { return slug }
        if provider.models.contains(slug) { return slug }
        let map = aliases(for: provider, cacheURL: cacheURL)
        return map.first { $0.slug == slug }?.model ?? provider.defaultModel
    }
}
