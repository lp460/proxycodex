import XCTest
@testable import AIProviderSwitcherCore

final class ModelMasqueradeTests: XCTestCase {
    private var cache: URL!

    override func setUp() {
        super.setUp()
        cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-masq-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        super.tearDown()
    }

    private func writeCache(_ models: [(String, String)]) throws {
        let entries = models.map { ["slug": $0.0, "visibility": $0.1] }
        try JSONSerialization.data(withJSONObject: ["models": entries]).write(to: cache, options: [.atomic])
    }

    func testOnlyRoutedProvidersMasquerade() {
        for provider in ProviderCatalog.default.providers {
            let expected = CodexConfigGenerator.proxyPort(for: provider.id) != nil
            XCTAssertEqual(ModelMasquerade.masquerades(provider), expected, provider.id)
        }
        // Codex built-ins talk to their endpoint directly: nothing can rewrite
        // the model name for them.
        XCTAssertFalse(ModelMasquerade.masquerades(ProviderCatalog.default[id: "ollama"]!))
        XCTAssertFalse(ModelMasquerade.masquerades(ProviderCatalog.default[id: "openai"]!))
    }

    func testDefaultModelTakesTheTopNativeSlugAndRoundTrips() throws {
        try writeCache([("gpt-5.6-sol", "list"), ("gpt-5.6-terra", "list"), ("gpt-reserve", "hide")])
        let claude = try XCTUnwrap(ProviderCatalog.default[id: "claude"])
        let aliases = ModelMasquerade.aliases(for: claude, cacheURL: cache)

        XCTAssertEqual(aliases.first?.slug, "gpt-5.6-sol")
        XCTAssertEqual(aliases.first?.model, claude.defaultModel)
        XCTAssertEqual(ModelMasquerade.slug(for: claude.defaultModel, provider: claude, cacheURL: cache),
                       "gpt-5.6-sol")
        XCTAssertEqual(ModelMasquerade.model(for: "gpt-5.6-sol", provider: claude, cacheURL: cache),
                       claude.defaultModel)
        // Every provider model must be reachable through some slug.
        for model in claude.models {
            let slug = ModelMasquerade.slug(for: model, provider: claude, cacheURL: cache)
            XCTAssertEqual(ModelMasquerade.model(for: slug, provider: claude, cacheURL: cache), model, model)
        }
    }

    func testHiddenNativeSlugsResolveToTheDefaultModel() throws {
        try writeCache([("gpt-5.6-sol", "list"), ("codex-auto-review", "hide")])
        let deepseek = try XCTUnwrap(ProviderCatalog.default[id: "deepseek"])
        let aliases = ModelMasquerade.aliases(for: deepseek, cacheURL: cache)

        let hidden = try XCTUnwrap(aliases.first { $0.slug == "codex-auto-review" })
        XCTAssertFalse(hidden.listed)
        XCTAssertEqual(hidden.model, deepseek.defaultModel)
        // Slugs Codex uses internally must still reach a real model.
        XCTAssertEqual(ModelMasquerade.model(for: "codex-auto-review", provider: deepseek, cacheURL: cache),
                       deepseek.defaultModel)
    }

    func testPickerShowsOneSlugPerProviderModel() throws {
        try writeCache([("gpt-5.6-sol", "list"), ("gpt-5.6-terra", "list"), ("gpt-5.6-luna", "list"),
                        ("gpt-5.5", "list"), ("gpt-reserve", "hide")])
        let deepseek = try XCTUnwrap(ProviderCatalog.default[id: "deepseek"])   // 2 models
        let aliases = ModelMasquerade.aliases(for: deepseek, cacheURL: cache)

        // No duplicate entries pointing at the same model in the picker.
        XCTAssertEqual(aliases.filter { $0.listed }.count, deepseek.models.count)
        XCTAssertEqual(Set(aliases.filter { $0.listed }.map { $0.model }), Set(deepseek.models))
        // Hidden slugs come from the cache and from the fallback pool, so an
        // internal Codex request always resolves.
        XCTAssertEqual(aliases.filter { !$0.listed }.map { $0.slug },
                       ["gpt-reserve", "codex-auto-review"])
    }

    func testUnknownSlugFallsBackToTheDefaultModel() throws {
        try writeCache([("gpt-5.6-sol", "list")])
        let glm = try XCTUnwrap(ProviderCatalog.default[id: "glm"])
        XCTAssertEqual(ModelMasquerade.model(for: "gpt-9-imaginary", provider: glm, cacheURL: cache),
                       glm.defaultModel)
        // A real model name is left alone, so probes keep working.
        XCTAssertEqual(ModelMasquerade.model(for: "glm-4.6", provider: glm, cacheURL: cache), "glm-4.6")
    }

    func testMissingCacheStillYieldsNativeSlugs() {
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        let aliases = ModelMasquerade.aliases(
            for: deepseek,
            cacheURL: URL(fileURLWithPath: "/nonexistent-models-cache.json")
        )
        XCTAssertEqual(aliases.first?.slug, "gpt-5.6-sol")
        XCTAssertTrue(aliases.allSatisfy { $0.slug.hasPrefix("gpt-") || $0.slug.hasPrefix("codex-") })
        XCTAssertTrue(aliases.allSatisfy { deepseek.models.contains($0.model) })
    }

    func testNonRoutedProviderKeepsItsRealModelNames() {
        let ollama = ProviderCatalog.default[id: "ollama"]!
        XCTAssertEqual(ModelMasquerade.slug(for: "qwen3-coder", provider: ollama, cacheURL: cache),
                       "qwen3-coder")
        XCTAssertEqual(ModelMasquerade.model(for: "qwen3-coder", provider: ollama, cacheURL: cache),
                       "qwen3-coder")
    }
}
