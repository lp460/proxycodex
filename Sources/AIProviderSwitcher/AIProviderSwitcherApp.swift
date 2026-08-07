import SwiftUI
import AIProviderSwitcherCore

@main
struct AIProviderSwitcherApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // A native panel (not a plain submenu) so the provider grid, logs,
        // key sheet and Claude status live in one rich, stable SwiftUI surface.
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            Image(systemName: state.menuBarIcon)
                .help(state.menuBarTooltip)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppState {
    var menuBarIcon: String {
        switch snapshot.compatibility {
        case .compatible: return "bolt.horizontal.circle.fill"
        case .incompatible: return "exclamationmark.triangle.fill"
        case .untested: return "circle.dashed"
        }
    }

    var menuBarTooltip: String {
        let provider = activeProvider?.displayName ?? "AI Provider Switcher"
        return "\(provider) · \(snapshot.activeModel)"
    }
}
