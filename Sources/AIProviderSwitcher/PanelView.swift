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
                    if state.catalogConflict {
                        catalogConflictNotice
                    }
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
                Text("Codex natif par défaut · \(state.keyCount) clé(s) injectée(s)")
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
                .accessibilityHidden(true)
            Text(statusLabel)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusColor.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("État de la configuration")
        .accessibilityValue(statusLabel)
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
                        hasKey: provider.isKeyless || state.hasKey(for: provider.id),
                        tap: {
                            Task { await state.select(providerID: provider.id) }
                        },
                        keyTap: {
                            draftKey = ""
                            state.presentKeySheet(for: provider.id)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { keyFieldFocused = true }
                        },
                        isInteractionDisabled: state.isScreenshotMode
                    )
                }
            }
            modelPicker
            Text("Un clic sur un fournisseur : config appliquée + ChatGPT/Codex relancé avec les clés.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            openCodeStatus
        }
    }

    /// OpenCode is detected, not required: the Zen gateway it talks to answers
    /// without the CLI, so the line states where models and credential come from.
    private var openCodeStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: state.openCode == nil ? "questionmark.circle" : "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(state.openCode == nil ? Color.secondary : Color.green)
            Text(openCodeStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var openCodeStatusText: String {
        guard let install = state.openCode else {
            return "OpenCode CLI non détecté · passerelle Zen publique (palier gratuit)"
        }
        let version = install.version.map { "CLI \($0)" } ?? "CLI"
        return install.hasZenCredential
            ? "OpenCode \(version) détecté · clé Zen d’OpenCode réutilisée"
            : "OpenCode \(version) détecté · palier gratuit (clé publique)"
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
                ForEach(state.selectableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(state.isScreenshotMode)
            if let exposed = state.exposedModel {
                Text("Codex voit « \(exposed) » : contrat natif complet (outils, MCP, plugins).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var catalogConflictNotice: some View {
        Label("Catalogue Codex personnalisé détecté : la liste générée n’est pas active.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Avertissement : catalogue Codex personnalisé détecté")

    }

    // MARK: Keys

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelTitle(state.editingKey ? "Clé API · \(state.keyEditingProvider?.displayName ?? "Provider")" : "Clés API")
            if state.editingKey && !state.isScreenshotMode {
                keyEditor
            } else {
                HStack(spacing: 8) {
                    Image(systemName: state.activeProvider?.isKeyless == true || state.isActiveNative
                          ? "checkmark.seal.fill"
                          : (state.hasKeyForActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(state.activeProvider?.isKeyless == true || state.isActiveNative || state.hasKeyForActive ? .green : .orange)
                    Text(state.activeProvider?.isKeyless == true || state.isActiveNative
                         ? "Aucune clé requise"
                         : (state.hasKeyForActive
                            ? "Clé enregistrée pour \(state.activeProvider?.displayName ?? "ce provider")"
                            : "Aucune clé pour \(state.activeProvider?.displayName ?? "ce provider")"))
                        .font(.callout)
                    Spacer()
                    Button("Saisir une clé…") {
                        draftKey = ""
                        state.presentKeySheet(for: state.snapshot.activeProviderID)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { keyFieldFocused = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isScreenshotMode)
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
                TextField(state.keyEditingProvider.map { state.hasKey(for: $0.id) ? "Clé existante — tapez pour remplacer" : "sk-…" } ?? "sk-…", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .focused($keyFieldFocused)
                    .onSubmit { injectKey() }
            }
            HStack(spacing: 8) {
                Button("Coller") { pasteKey() }
                    .controlSize(.small)
                if let provider = state.keyEditingProvider, state.hasKey(for: provider.id) {
                    Button("Voir la clé") { showExistingKey() }
                        .controlSize(.small)
                }
                Button("Injecter") { injectKey() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedKey.isEmpty)
                Button("Annuler") {
                    draftKey = ""
                    state.dismissKeyEditor()
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
                .disabled(state.isScreenshotMode)

                Button {
                    Task { await state.relaunchChatGPT() }
                } label: {
                    Label("Relancer ChatGPT/Codex", systemImage: "arrow.counterclockwise.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Redémarre l'app ChatGPT pour appliquer les clés injectées au sélecteur de modèles")
                .disabled(state.isScreenshotMode)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await state.runAllTests() }
                } label: {
                    if state.testing {
                        Label("Test en cours…", systemImage: "hourglass")
                    } else {
                        Label("Tester tous", systemImage: "checkmark.shield")
                    }
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.testing || state.isScreenshotMode)

                Button {
                    Task { await state.refreshModels() }
                } label: {
                    Label(state.refreshingModels ? "Lecture…" : "Rafraîchir les modèles",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Demande à chaque provider la liste des modèles qu'il sert réellement")
                    .disabled(state.refreshingModels || state.isScreenshotMode)
            }

            Text(modelSourceText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the model list comes from, so a stale picker is never a mystery.
    private var modelSourceText: String {
        if state.testing { return "Test en cours…" }
        guard let date = state.lastModelRefresh else {
            return "Modèles : listes déclarées. « Rafraîchir » interroge chaque provider."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Modèles lus auprès des providers à \(formatter.string(from: date)). Codex n'expose que ses propres slugs, donc au plus autant de modèles qu'il a de slugs."
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = state.statusMessage {
                Label {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Toggle("Clé locale (0600)", isOn: Binding(
                    get: { state.persistenceEnabled },
                    set: { on in on ? state.enablePersistence() : state.disablePersistence() }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
                .disabled(state.isScreenshotMode)
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
        guard let provider = state.keyEditingProvider else { return }
        draftKey = state.keyStore.secret(for: provider.id)?.asString() ?? ""
    }

    private func injectKey() {
        guard !trimmedKey.isEmpty else { return }
        let providerID = state.keyEditingProvider?.id
        Task { await state.setSessionKey(trimmedKey, for: providerID) }
        draftKey = ""
        state.dismissKeyEditor()
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
    let isInteractionDisabled: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: tap) { cardBody }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .help(isActive ? "Provider actif : \(provider.displayName)" : "Activer \(provider.displayName)")
                .disabled(isInteractionDisabled)

            if provider.requiresKey {
                Button(action: keyTap) { keyIcon }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hasKey ? "Modifier la clé" : "Saisir la clé")
                    .help(hasKey ? "Modifier la clé \(provider.displayName)" : "Saisir la clé \(provider.displayName)")
                    .disabled(isInteractionDisabled)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                      ? provider.brandColor.opacity(isHovered ? 0.16 : 0.10)
                      : Color(nsColor: .windowBackgroundColor).opacity(isHovered ? 0.72 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? provider.brandColor.opacity(0.6) : Color.secondary.opacity(isHovered ? 0.28 : 0), lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .accessibilityElement(children: .contain)
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
