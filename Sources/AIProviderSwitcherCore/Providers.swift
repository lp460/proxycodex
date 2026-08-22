import Foundation

public enum WireAPI: String, Sendable, Equatable, Codable {
    /// OpenAI Responses API (`/v1/responses`), used by Codex.
    case responses
    /// OpenAI Chat Completions API (`/v1/chat/completions`).
    case chat
}

public enum AuthScheme: String, Sendable, Equatable, Codable {
    case bearer   // Authorization: Bearer <key>
    case none     // no auth header (e.g. local Ollama without gateway auth)
}

/// Description of a backend provider. Contains no secret material.
///
/// `models` carries the provider's full list of latest models so the UI can
/// offer a picker and Codex's config can be written with the selected model.
public struct Provider: Sendable, Identifiable, Equatable, Hashable, Codable {
    public let id: String                  // e.g. "deepseek"
    public let displayName: String         // e.g. "DeepSeek"
    public let baseURL: URL                // e.g. https://api.deepseek.com/v1
    public let environmentVariable: String // e.g. DEEPSEEK_API_KEY ("" if keyless)
    public let models: [String]            // all available (latest) models
    public let defaultModel: String        // initially selected model (member of `models`)
    public let wireAPI: WireAPI
    public let authScheme: AuthScheme
    public let supportsResponses: Bool     // claimed; verified at runtime by CompatibilityChecker
    public let supportsTools: Bool         // function tools can be forwarded by the adapter
    public let supportsApplyPatch: Bool    // Codex's apply_patch tool (any flavor)
    public let supportsImages: Bool        // provider/model accepts image input
    public let supportsWebSearch: Bool     // provider/model can really run a web search
    public let supportsParallelToolCalls: Bool
    /// True only for providers implementing Codex's **native** tool flavors
    /// (freeform custom tools such as `apply_patch`/`exec`, `local_shell`,
    /// `code_mode_only`). That wire contract is OpenAI-specific; for every other
    /// provider the adapter bridges those tools to function tools, so the
    /// catalog must advertise the `function` flavor instead.
    public let supportsCustomTools: Bool
    public let requiresKey: Bool
    public let configProviderIDDirect: String // model_provider id used in direct (no-proxy) config

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        environmentVariable: String,
        models: [String]? = nil,
        defaultModel: String,
        wireAPI: WireAPI = .responses,
        authScheme: AuthScheme = .bearer,
        supportsResponses: Bool = true,
        supportsTools: Bool = false,
        supportsApplyPatch: Bool = false,
        supportsImages: Bool = false,
        supportsWebSearch: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsCustomTools: Bool = false,
        requiresKey: Bool = true,
        configProviderIDDirect: String
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.environmentVariable = environmentVariable
        let resolved: [String] = (models?.isEmpty == false) ? models! : [defaultModel]
        self.models = resolved
        self.defaultModel = resolved.contains(defaultModel) ? defaultModel : resolved[0]
        self.wireAPI = wireAPI
        self.authScheme = authScheme
        self.supportsResponses = supportsResponses
        self.supportsTools = supportsTools
        self.supportsApplyPatch = supportsApplyPatch
        self.supportsImages = supportsImages
        self.supportsWebSearch = supportsWebSearch
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsCustomTools = supportsCustomTools
        self.requiresKey = requiresKey
        self.configProviderIDDirect = configProviderIDDirect
    }

    public var isKeyless: Bool { !requiresKey }
}

public struct ProviderCatalog: Sendable, Equatable {
    public let providers: [Provider]
    public init(providers: [Provider]) { self.providers = providers }
    public func provider(id: String) -> Provider? { providers.first { $0.id == id } }
    public subscript(id id: String) -> Provider? { provider(id: id) }

    public static let `default`: ProviderCatalog = ProviderCatalog(providers: [
        Provider(
            id: "openai",
            displayName: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            // OpenAI auth is handled by Codex itself (native). From this app's
            // perspective OpenAI is keyless: we never inject or store an OpenAI key.
            environmentVariable: "",
            // GPT-5.6 family (flagship). `gpt-5.6` is the alias for sol.
            models: ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                     "gpt-5.3-codex-spark", "gpt-5.5"],
            defaultModel: "gpt-5.6",
            supportsTools: true,
            supportsApplyPatch: true,
            supportsImages: true,
            supportsWebSearch: true,
            supportsParallelToolCalls: true,
            // Only OpenAI speaks Codex's native freeform/custom tool wire format.
            supportsCustomTools: true,
            requiresKey: false,
            configProviderIDDirect: "openai"
        ),
        Provider(
            id: "deepseek",
            displayName: "DeepSeek",
            // DeepSeek-V4. Responses API serves `deepseek-v4-flash` (pro coming soon).
            baseURL: URL(string: "https://api.deepseek.com/v1")!,
            environmentVariable: "DEEPSEEK_API_KEY",
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            defaultModel: "deepseek-v4-flash",
            // Full agentic set: shell, apply_patch, plan updates and MCP tools
            // all reach the model as function tools through the adapter bridge.
            supportsTools: true,
            supportsApplyPatch: true,
            supportsParallelToolCalls: true,
            configProviderIDDirect: "deepseek"
        ),
        Provider(
            id: "glm",
            displayName: "GLM (Z.ai)",
            // GLM-5.2 is Z.ai's strongest coding model. OpenAI-compatible base.
            baseURL: URL(string: "https://api.z.ai/api/paas/v4")!,
            environmentVariable: "ZAI_API_KEY",
            models: ["glm-5.2", "glm-4.6", "glm-4.5"],
            defaultModel: "glm-5.2",
            // Same bridged agentic set as DeepSeek.
            supportsTools: true,
            supportsApplyPatch: true,
            supportsParallelToolCalls: true,
            configProviderIDDirect: "glm"
        ),
        Provider(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            environmentVariable: "OPENROUTER_API_KEY",
            // OpenRouter exposes upstream models as `provider/model-id`.
            models: ["openai/gpt-5.6-luna", "openai/gpt-5.6-sol", "openai/gpt-5.6-terra",
                     "deepseek/deepseek-v4-flash", "z-ai/glm-5.2"],
            defaultModel: "openai/gpt-5.6-luna",
            // OpenRouter exposes many upstream function-tool contracts, but not
            // one universal Codex custom-tool contract: the bridge normalizes it.
            supportsTools: true,
            supportsApplyPatch: true,
            supportsImages: true,
            supportsParallelToolCalls: true,
            configProviderIDDirect: "openrouter"
        ),
        Provider(
            id: "ollama",
            displayName: "Ollama",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            environmentVariable: "",
            // gpt-oss = OpenAI open-weight model; qwen3-coder & llama3.3 are local options.
            models: ["gpt-oss:120b", "gpt-oss:20b", "qwen3-coder", "llama3.3"],
            defaultModel: "gpt-oss:120b",
            authScheme: .none,
            // Ollama is a Codex built-in: it has no adapter proxy, so the
            // catalog must advertise the function flavor of every tool. Local
            // models are single-call oriented, hence no parallel tool calls.
            supportsTools: true,
            supportsApplyPatch: true,
            requiresKey: false,
            configProviderIDDirect: "ollama"
        ),
        Provider(
            id: "opencode",
            displayName: "OpenCode Zen",
            // The OpenCode CLI is an agent, not an HTTP backend. What it talks
            // to is OpenCode Zen, an OpenAI-compatible gateway that also serves
            // /v1/responses. The free tier runs under the documented `public`
            // key, so no key to enter; the adapter prefers OpenCode's own
            // credential when `opencode auth login` stored one.
            baseURL: URL(string: "https://opencode.ai/zen/v1")!,
            environmentVariable: "",
            // Free tier, as listed by `opencode models opencode`.
            models: ["big-pickle", "hy3-free", "mimo-v2.5-free",
                     "muse-spark-1.2-contributor-free", "nemotron-3-ultra-free",
                     "nemotron-3.5-lightning-free", "x-preview-f-free"],
            defaultModel: "big-pickle",
            supportsTools: true,
            supportsApplyPatch: true,
            // Free-tier models are small: no image input, one tool call at a time.
            requiresKey: false,
            configProviderIDDirect: "opencode"
        ),
        Provider(
            id: "claude",
            displayName: "Claude Code",
            // Auth comes from Claude Code's own environment (~/.claude/settings.json:
            // ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL) via the adapter proxy —
            // no API key to enter. The proxy (port 18891) translates
            // Responses <-> Messages against that base URL.
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            environmentVariable: "",
            // Latest Claude models (4.6 -> 5.0), as used by Claude Code 2.1.
            models: ["claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                     "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"],
            // haiku-4-5: seul modèle non rate-limité sur le compte actuel.
            defaultModel: "claude-haiku-4-5",
            // The adapter bridges every Codex tool flavor to Anthropic tools and
            // restores the original items, and maps Codex's hosted web_search to
            // Anthropic's own server-side web search.
            supportsTools: true,
            supportsApplyPatch: true,
            supportsImages: true,
            supportsWebSearch: true,
            supportsParallelToolCalls: true,
            requiresKey: false,
            configProviderIDDirect: "claude"
        )
    ])
}
