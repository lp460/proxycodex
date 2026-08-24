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

    /// Native slugs, read **only** from the catalog Codex fetched.
    ///
    /// Nothing is ever invented here. A slug absent from that cache has no
    /// metadata, and Codex requires every field of its catalog schema: a
    /// hand-written entry makes it reject `config.toml` as a whole — losing the
    /// user's MCP servers, sandbox policy and everything else. When the cache is
    /// unreadable this returns an empty list, which disables masquerading and
    /// falls back to the provider's real model names.
    public static func nativeModels(cacheURL: URL) -> [NativeModel] {
        guard let data = try? Data(contentsOf: cacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = object["models"] as? [[String: Any]] else { return [] }
        var models: [NativeModel] = []
        var seen: Set<String> = []
        for entry in cached {
            guard let slug = entry["slug"] as? String, !slug.isEmpty, !seen.contains(slug) else { continue }
            seen.insert(slug)
            models.append(NativeModel(slug: slug, listed: (entry["visibility"] as? String) != "hide"))
        }
        return models
    }

    /// How many provider models Codex can expose while masquerading: one per
    /// listed native slug. Hidden slugs (`codex-auto-review`, `gpt-reserve`)
    /// are internal to Codex and never take a provider model of their own.
    public static func listedSlotCount(cacheURL: URL) -> Int {
        nativeModels(cacheURL: cacheURL).filter(\.listed).count
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

    /// Provider models that have a native slug, hence are selectable while
    /// masquerading. Codex has a finite list of slugs, so a provider offering
    /// more models than that exposes the first ones only — better than pointing
    /// two slugs at the same model, or a slug at the wrong one.
    public static func exposableModels(for provider: Provider, cacheURL: URL) -> [String] {
        guard masquerades(provider) else { return provider.models }
        let map = aliases(for: provider, cacheURL: cacheURL).filter(\.listed)
        guard !map.isEmpty else { return provider.models }
        return provider.models.filter { model in map.contains { $0.model == model } }
    }

    /// Resolves the user's chosen subset against the provider's current model
    /// list. When the provider fits in the native slug slots, the full list is
    /// kept untouched; otherwise the chosen models are kept (bounded by the
    /// slots), with the provider's default model always guaranteed a slot so
    /// Codex's internal requests keep resolving. A missing cache disables
    /// masquerading, so the full list is returned instead.
    public static func resolvedSelection(
        for provider: Provider,
        selection: [String]?,
        cacheURL: URL
    ) -> [String] {
        guard masquerades(provider) else { return provider.models }
        let slots = listedSlotCount(cacheURL: cacheURL)
        guard slots > 0, provider.models.count > slots else { return provider.models }
        let available = Set(provider.models)
        let picked = Set((selection ?? []).filter { available.contains($0) })
        // Default model first: it always takes the primary native slug. Without
        // a user selection, keep the provider's first models (default + the
        // next ones) so the picker never shrinks to a single model.
        let ordered = [provider.defaultModel] + provider.models
        var result: [String] = []
        var seen: Set<String> = []
        for model in ordered {
            // Always keep the default; keep the chosen models when the user made
            // a choice, or the provider's first models when they did not.
            guard model == provider.defaultModel || picked.isEmpty || picked.contains(model) else { continue }
            if seen.insert(model).inserted { result.append(model) }
        }
        if result.count > slots { result = Array(result.prefix(slots)) }
        return result
    }

    /// The slug Codex must see for this provider model. Returns `model` itself
    /// for providers that do not masquerade — and for a model with no slug left,
    /// so the request still reaches the right model, only without the native
    /// feature contract.
    public static func slug(for model: String, provider: Provider, cacheURL: URL) -> String {
        guard masquerades(provider) else { return model }
        let map = aliases(for: provider, cacheURL: cacheURL)
        return map.first { $0.model == model && $0.listed }?.slug
            ?? map.first { $0.model == model }?.slug
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
