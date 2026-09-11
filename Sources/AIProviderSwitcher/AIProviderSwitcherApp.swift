import SwiftUI
import Sparkle
import AIProviderSwitcherCore

@main
struct AIProviderSwitcherApp: App {
    @StateObject private var state = AppState()

    // Keep a strong reference for the lifetime of the app. Development builds do
    // not contain the public update key, so they deliberately skip Sparkle.
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let publicKey, !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
    }

    var body: some Scene {
        // A native panel (not a plain submenu) so the provider grid, logs,
        // key sheet and Claude status live in one rich, stable SwiftUI surface.
        // No WindowGroup: the app is a menu-bar accessory, never a Dock app.
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
        let provider = activeProvider?.displayName ?? "ProxyCodex"
        return "\(provider) · \(snapshot.activeModel)"
    }
}
