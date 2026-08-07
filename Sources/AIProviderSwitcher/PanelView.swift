import SwiftUI
import AppKit
import AIProviderSwitcherCore

/// Main panel shown when the user clicks the status-bar item (`.window` style).
/// Deliberately minimal: provider statuses (connectivity + key) and key entry.
/// Model choice happens inside Codex (menu Modèle) — this bar only injects keys
/// and reports whether each provider is reachable.
struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var draftKey: String = ""
    @FocusState private var keyFieldFocused: Bool

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providerSection
                    keySection
                    relaunchSection
                }
                .padding(14)
            }
            // macOS 26 MenuBarExtra windows ignore the ScrollView's ideal height
            // and collapse to the fixed-size content only (header + footer). A
            // FIXED height keeps the viewport real.
            .frame(height: 470)
            Divider()
            footer
        }
        .frame(width: 372)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Provider Switcher")
                    .font(.headline)
                Text("Codex natif par défaut · \(state.keyStore.providerIDs.count) clé(s) injectée(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .padding(14)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusColor.opacity(0.14)))
    }

    private var statusColor: Color {
        switch state.snapshot.compatibility {
        case .compatible: return .green
        case .incompatible: return .red
        case .untested: return .secondary
        }
    }

    private var statusLabel: String {
        switch state.snapshot.compatibility {
        case .compatible: return "OK"
        case .incompatible: return "Erreur"
        case .untested: return state.isActiveNative ? "Native" : "Non testé"
        }
    }

    // MARK: Providers (status + key badge per provider)

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Fournisseurs")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(state.catalog.providers) { provider in
                    ProviderCard(
                        provider: provider,
                        isActive: provider.id == state.snapshot.activeProviderID,
                        status: state.snapshot.compatibility(for: provider.id),
                        hasKey: provider.isKeyless || state.keyStore.hasKey(provider.id)
                    ) {
                        Task { await state.select(providerID: provider.id) }
                    } keyTap: {
                        draftKey = ""
                        state.editingKey = true
                        Task { await state.select(providerID: provider.id) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { keyFieldFocused = true }
                    }
                }
            }
            modelPicker
            Text("Un clic sur un fournisseur : config appliquée + ChatGPT/Codex relancé avec les clés.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Model selector for the active provider. The Desktop picker is fed by
    /// OpenAI's own backend (quota/limits), so switching happens here instead.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            panelTitle("Modèle actif")
            Picker("Modèle", selection: Binding(
                get: { state.snapshot.activeModel },
                set: { newValue in Task { await state.setModel(newValue) } }
            )) {
                ForEach(state.activeProvider?.models ?? [], id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: Keys

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle("Clés API")
            if state.editingKey {
                keyEditor
            } else {
                HStack(spacing: 8) {
                    Image(systemName: state.hasKeyForActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasKeyForActive ? .green : .orange)
                    Text(state.hasKeyForActive
                         ? "Clé enregistrée pour \(state.activeProvider?.displayName ?? "ce provider")"
                         : (state.activeProvider?.isKeyless == true || state.isActiveNative
                            ? "Aucune clé requise"
                            : "Aucune clé pour \(state.activeProvider?.displayName ?? "ce provider")"))
                        .font(.callout)
                    Spacer()
                    Button("Saisir une clé…") {
                        draftKey = ""
                        state.presentKeySheet()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { keyFieldFocused = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    /// Inline key editor. Lives inside the panel (a `.sheet` would close the
    /// MenuBarExtra window), so the field always receives keyboard input.
    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                TextField(state.hasKeyForActive ? "Clé existante — tapez pour remplacer" : "sk-…", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .focused($keyFieldFocused)
                    .onSubmit { injectKey() }
            }
            HStack(spacing: 8) {
                Button("Coller") { pasteKey() }
                    .controlSize(.small)
                if state.hasKeyForActive {
                    Button("Voir la clé") { showExistingKey() }
                        .controlSize(.small)
                }
                Button("Injecter") { injectKey() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedKey.isEmpty)
                Button("Annuler") {
                    draftKey = ""
                    state.editingKey = false
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Relaunch Codex with injected keys

    private var relaunchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    state.launchCodexCLI()
                } label: {
                    Label("Lancer Codex CLI", systemImage: "terminal.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Lance Codex dans Terminal avec le provider actif et sa clé (chemin fiable pour DeepSeek/GLM/OpenRouter)")

                Button {
                    Task { await state.relaunchChatGPT() }
                } label: {
                    Label("Relancer ChatGPT/Codex", systemImage: "arrow.counterclockwise.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Redémarre l'app ChatGPT pour appliquer les clés injectées au sélecteur de modèles")
            }

            HStack(spacing: 8) {
                Button("Tester tous") { Task { await state.runAllTests() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.testing)
                Text(state.testing ? "Test en cours…"
                     : "Les modèles DeepSeek/GLM/OpenRouter s'exécutent via Codex CLI. L'app ChatGPT les affiche mais ne les exécute pas avec un compte ChatGPT (restriction OpenAI).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = state.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Toggle("Clé locale (0600)", isOn: Binding(
                    get: { state.persistenceEnabled },
                    set: { on in on ? state.enablePersistence() : state.disablePersistence() }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: Helpers

    private var trimmedKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pasteKey() {
        if let s = NSPasteboard.general.string(forType: .string) {
            draftKey = s
        }
    }

    private func showExistingKey() {
        guard let provider = state.activeProvider else { return }
        draftKey = state.keyStore.secret(for: provider.id)?.asString() ?? ""
    }

    private func injectKey() {
        guard !trimmedKey.isEmpty else { return }
        Task { await state.setSessionKey(trimmedKey) }
        draftKey = ""
        state.editingKey = false
    }

    private func panelTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Provider card

struct ProviderCard: View {
    let provider: Provider
    let isActive: Bool
    let status: CompatibilityState
    let hasKey: Bool
    let tap: () -> Void
    let keyTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: tap) { cardBody }
                .buttonStyle(.plain)

            if provider.requiresKey {
                Button(action: keyTap) { keyIcon }
                    .buttonStyle(.plain)
                    .help(hasKey ? "Modifier la clé \(provider.displayName)" : "Saisir la clé \(provider.displayName)")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? provider.brandColor.opacity(0.10) : Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? provider.brandColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        )
    }

    private var cardBody: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(provider.brandColor.opacity(0.15))
                Image(systemName: provider.brandSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider.brandColor)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var keyIcon: some View {
        Image(systemName: hasKey ? "key.fill" : "key")
            .font(.system(size: 13))
            .foregroundStyle(hasKey ? .green : .secondary)
    }

    private var detailText: String {
        if !hasKey && provider.requiresKey { return "Clé manquante" }
        switch status {
        case .compatible: return "Connecté"
        case .incompatible(let reason): return "Erreur · \(reason)"
        case .untested: return "Non testé"
        }
    }

    private var statusDotColor: Color {
        switch status {
        case .compatible: return .green
        case .incompatible: return .red
        case .untested: return .gray.opacity(0.5)
        }
    }
}
