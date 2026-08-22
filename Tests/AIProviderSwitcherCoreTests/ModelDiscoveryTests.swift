import XCTest
@testable import AIProviderSwitcherCore

final class ModelDiscoveryTests: XCTestCase {

    private func discovered(_ models: [String], source: String = "upstream") -> DiscoveredModels {
        DiscoveredModels(models: models, source: source, fetchedAt: Date())
    }

    func testDiscoveryGoesThroughTheAdapterWhenThereIsOne() {
        let discovery = ModelDiscovery()
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        XCTAssertEqual(discovery.discoveryURL(for: deepseek)?.absoluteString,
                       "http://127.0.0.1:18888/_switcher/upstream-models")
        // Ollama has no adapter: it is queried directly.
        let ollama = ProviderCatalog.default[id: "ollama"]!
        XCTAssertEqual(discovery.discoveryURL(for: ollama)?.absoluteString,
                       "http://127.0.0.1:11434/v1/models")
        // OpenAI is native: nothing to discover.
        XCTAssertNil(discovery.discoveryURL(for: ProviderCatalog.default[id: "openai"]!))
    }

    /// A model released after this build must show up, which is the whole point.
    func testNewlyReleasedModelIsAdopted() {
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        let models = ModelDiscovery.resolvedModels(
            for: deepseek,
            discovered: discovered(["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-v5-brand-new"])
        )
        XCTAssertTrue(models.contains("deepseek-v5-brand-new"))
        // The default keeps the primary native slug, so it stays first.
        XCTAssertEqual(models.first, deepseek.defaultModel)
    }

    func testDefaultModelSurvivesAProviderDroppingIt() {
        let glm = ProviderCatalog.default[id: "glm"]!
        let models = ModelDiscovery.resolvedModels(for: glm, discovered: discovered(["glm-9-new"]))
        XCTAssertEqual(models, [glm.defaultModel, "glm-9-new"])
    }

    /// OpenRouter serves hundreds of models: that is not a picker, and the
    /// masquerade only has a handful of slugs anyway.
    func testHugeCatalogsKeepTheCuratedList() {
        let openrouter = ProviderCatalog.default[id: "openrouter"]!
        let many = (0..<400).map { "vendor/model-\($0)" }
        XCTAssertEqual(ModelDiscovery.resolvedModels(for: openrouter, discovered: discovered(many)),
                       openrouter.models)
    }

    func testNoAnswerKeepsTheDeclaredList() {
        let claude = ProviderCatalog.default[id: "claude"]!
        XCTAssertEqual(ModelDiscovery.resolvedModels(for: claude, discovered: nil), claude.models)
        XCTAssertEqual(ModelDiscovery.resolvedModels(for: claude, discovered: discovered([])),
                       claude.models)
    }

    func testIdentifiersAcceptEveryShapeProvidersUse() {
        XCTAssertEqual(ModelDiscovery.identifiers(in: ["models": ["a", "b"]]), ["a", "b"])
        XCTAssertEqual(ModelDiscovery.identifiers(in: ["data": [["id": "a"], ["id": "b"]]]), ["a", "b"])
        XCTAssertEqual(ModelDiscovery.identifiers(in: ["models": [["slug": "a"]]]), ["a"])
        // Duplicates collapse, order is the provider's.
        XCTAssertEqual(ModelDiscovery.identifiers(in: ["data": [["id": "b"], ["id": "a"], ["id": "b"]]]),
                       ["b", "a"])
        XCTAssertTrue(ModelDiscovery.identifiers(in: ["error": "nope"]).isEmpty)
    }

    func testDiscoveredListSurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aps-discovered-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DiscoveredModelStore(url: url)
        XCTAssertTrue(store.load().isEmpty)

        try store.save(["deepseek": discovered(["deepseek-v4-pro"], source: "upstream")])
        XCTAssertEqual(store.load()["deepseek"]?.models, ["deepseek-v4-pro"])
        XCTAssertEqual(store.load()["deepseek"]?.source, "upstream")
    }

    func testProviderCopyKeepsIdentityAndCapabilities() {
        let deepseek = ProviderCatalog.default[id: "deepseek"]!
        let refreshed = deepseek.withModels(["a", "b"])
        XCTAssertEqual(refreshed.models, ["a", "b"])
        XCTAssertEqual(refreshed.id, deepseek.id)
        XCTAssertEqual(refreshed.supportsApplyPatch, deepseek.supportsApplyPatch)
        XCTAssertEqual(refreshed.environmentVariable, deepseek.environmentVariable)
        // An empty answer must never erase the declared list.
        XCTAssertEqual(deepseek.withModels([]).models, deepseek.models)
    }
}
