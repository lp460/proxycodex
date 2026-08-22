import SwiftUI
import AIProviderSwitcherCore

/// Shared visual identity for each provider (used by the panel and the key sheet).
extension Provider {
    var brandColor: Color {
        switch id {
        case "openai": return .teal
        case "deepseek": return .blue
        case "glm": return .orange
        case "openrouter": return .purple
        case "ollama": return .brown
        case "claude": return .red
        case "opencode": return .indigo
        default: return .accentColor
        }
    }

    var brandSymbol: String {
        switch id {
        case "openai": return "sparkles"
        case "deepseek": return "wave.3.forward"
        case "glm": return "atom"
        case "openrouter": return "shuffle"
        case "ollama": return "hare.fill"
        case "claude": return "bubble.left.and.bubble.right.fill"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        default: return "key.fill"
        }
    }

    /// Short label under the name, e.g. the default model or "Native".
    var brandDetail: String {
        switch id {
        case "openai": return "Native (config Codex)"
        case "ollama": return "Local"
        default: return defaultModel
        }
    }
}