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
    @State private var maintenanceExpanded = false
    @State private var exposedModelsExpanded = false
    @FocusState private var keyFieldFocused: Bool

    private let providerColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if state.catalogConflict {
                        catalogConflictNotice
                    }
                    providerSection
                    modelSection
                    keySection
                    launchSection
                    maintenanceSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            // macOS 26 MenuBarExtra windows ignore the ScrollView's ideal height
            // and collapse to the fixed-size content only (header + footer). A
            // FIXED height keeps the viewport real.
            .frame(height: 500)
            Divider()
            footer
        }
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
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

            VStack(alignment: .leading, spacing: 3) {
                Text("AI Provider Switcher")
                    .font(.system(size: 15, weight: .semibold))
                Text(activeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var activeSummary: String {
        let providerName = state.activeProvider?.displayName ?? "Provider"
        guard !state.snapshot.activeModel.isEmpty else { return providerName }
        return "\(providerName) · \(state.snapshot.activeModel)"
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Fournisseur")
            LazyVGrid(columns: providerColumns, spacing: 10) {
                ForEach(state.catalog.providers) { provider in
                    ProviderCard(
                        provider: provider,
                        isActive: provider.id == state.snapshot.activeProviderID,
                        status: state.snapshot.compatibility(for: provider.id),
                        hasKey: state.hasKey(for: provider.id),
                        tap: {
                            Task { await state.select(providerID: provider.id) }
                        },
                        keyTap: { editKey(for: provider) },
                        isInteractionDisabled: state.isScreenshotMode
                    )
                }
            }

            SecondaryInfoRow(
                text: "Un clic applique la configuration et relance ChatGPT/Codex.",
                symbol: "info.circle"
            )
        }
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Modèle")

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
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(state.isScreenshotMode)

            if let exposed = state.exposedModel {
                SecondaryInfoRow(
                    text: "Codex voit « \(exposed) » : contrat natif complet (outils, MCP, plugins).",
                    symbol: "info.circle"
                )
            }
            if state.shouldShowModelPicker {
                modelSlotPicker
            }
        }
    }

    /// Selection of models exposed through Codex's finite native slugs.
    /// The existing `shouldShowModelPicker` business condition remains unchanged.
    private var modelSlotPicker: some View {
        DisclosureGroup(isExpanded: $exposedModelsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.allModelsForActive, id: \.self) { model in
                    Toggle(isOn: Binding(
                        get: { state.isModelSelected(model) },
                        set: { on in Task { await state.setModelSelected(model, selected: on) } }
                    )) {
                        HStack(spacing: 6) {
                            if state.modelLocked(model) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Text(model)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                   }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(state.isScreenshotMode || (state.isModelSelected(model) && state.modelLocked(model)))
                }

                SecondaryInfoRow(
                    text: "Le modèle par défaut et le modèle actif restent verrouillés.",
                    symbol: "lock.fill"
                )
            }
            .padding(.top, 8)
            .padding(.leading, 2)
        } label: {
            HStack {
                Text("Modèles exposés")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()
                Text("\(state.exposedModelCount) / \(state.modelSlots)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .controlSize(.small)
    }

    private var catalogConflictNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                "Catalogue Codex personnalisé détecté",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)

            Text("La liste générée par Proxycodex n’est pas active.")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.82))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityLabel("Avertissement : catalogue Codex personnalisé détecté")
    }

    // MARK: Keys

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.editingKey {
                SectionHeader(
                    "Clé API",
                    accessory: state.keyEditingProvider?.displayName
                )
            } else {
                SectionHeader("Clé API")
            }

            if state.editingKey && !state.isScreenshotMode {
                keyEditor
            } else {
                keySummary
            }
        }
    }

    private var keySummary: some View {
        HStack(spacing: 10) {
            Image(systemName: keyStatusSymbol)
                .foregroundStyle(keyStatusColor)

            Text(keyStatusText)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(keyActionButtonTitle) {
                editKey(for: state.snapshot.activeProviderID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isScreenshotMode)
        }
        .accessibilityElement(children: .combine)
    }

    private var keyIsConfigured: Bool {
        state.activeProvider?.isKeyless == true
            || state.isActiveNative
            || state.hasKeyForActive
    }

    private var keyStatusSymbol: String {
        keyIsConfigured ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var keyStatusColor: Color {
        keyIsConfigured ? .green : .orange
    }

    private var keyStatusText: String {
        let providerName = state.activeProvider?.displayName ?? "ce provider"
        if state.activeProvider?.isKeyless == true || state.isActiveNative {
            return "Aucune clé requise"
        }
        return state.hasKeyForActive
            ? "Clé enregistrée pour \(providerName)"
            : "Aucune clé pour \(providerName)"
    }

    private var keyActionButtonTitle: String {
        state.activeProvider?.isKeyless == true || state.isActiveNative
            ? "Modifier"
            : (state.hasKeyForActive ? "Modifier" : "Ajouter une clé")
    }

    /// Inline key editor. A `.sheet` would close the MenuBarExtra window, so the
    /// existing inline presentation and focus workaround are retained.
    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)

                TextField(keyPlaceholder, text: $draftKey)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .focused($keyFieldFocused)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            keyFieldFocused = true
                        }
                    }
                    .onSubmit { injectKey() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if let provider = state.keyEditingProvider {
                Text("Cible : \(provider.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Coller") { pasteKey() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if let provider = state.keyEditingProvider, state.hasKey(for: provider.id) {
                    Button("Voir la clé") { showExistingKey() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                Button("Annuler") {
                    draftKey = ""
                    state.dismissKeyEditor()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.secondary)

                Button("Injecter") { injectKey() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedKey.isEmpty || misroutedOpenRouterKey)
            }

            keyValidationMessages
        }
    }

    @ViewBuilder
    private var keyValidationMessages: some View {
        if let provider = state.keyEditingProvider, provider.id == "glm" {
            let trimmed = trimmedKey
            if trimmed.hasPrefix("sk-") {
                Label(
                    "Format DeepSeek/OpenRouter détecté — une clé Z.ai est de la forme ID.secret.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !trimmed.isEmpty && !trimmed.contains(".") {
                Label(
                    "Format attendu : ID.secret (la clé Z.ai contient un point).",
                    systemImage: "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        if trimmedKey.hasPrefix("sk-or-v1-"),
           let provider = state.keyEditingProvider,
           provider.id != "openrouter" {
            Label(
                "Clé OpenRouter détectée dans le champ \(provider.displayName). Utilisez la clé de la carte OpenRouter.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    // MARK: Launch

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Ouvrir")

            Button {
                state.launchCodexCLI()
            } label: {
                Label("Lancer Codex CLI", systemImage: "terminal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Lance Codex avec revue automatique des approbations (workspace-write) et la clé du provider actif")
            .disabled(state.isScreenshotMode)

            Button {
                Task { await state.relaunchChatGPT() }
            } label: {
                Label("Relancer ChatGPT / Codex", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Redémarre l'app ChatGPT pour appliquer les clés injectées au sélecteur de modèles")
            .disabled(state.isScreenshotMode)
        }
    }

    private var maintenanceSection: some View {
        DisclosureGroup(isExpanded: $maintenanceExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
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
                        Label(
                            state.refreshingModels ? "Lecture…" : "Rafraîchir les modèles",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Demande à chaque provider la liste des modèles qu'il sert réellement")
                    .disabled(state.refreshingModels || state.isScreenshotMode)
                }

                Divider()

                Text(modelSourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                openCodeStatus
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Maintenance")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()
                Text("Diagnostics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .controlSize(.small)
    }

    private var openCodeStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("OpenCode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            SecondaryInfoRow(
                text: openCodeStatusText,
                symbol: state.openCode == nil ? "questionmark.circle" : "checkmark.seal.fill",
                symbolColor: state.openCode == nil ? .secondary : .green
            )
        }
    }

    private var openCodeStatusText: String {
        guard let install = state.openCode else {
            return "CLI non détectée · saisissez une clé Zen, ou exécutez `opencode auth login`"
        }

        let version = install.version.map { "CLI \($0)" } ?? "CLI"
        if state.hasKey(for: "opencode") {
            return "\(version) détectée · clé Zen enregistrée"
        }
        return install.hasZenCredential
            ? "\(version) détectée · clé Zen d’OpenCode réutilisée"
            : "\(version) détectée · pas de clé Zen : le palier gratuit peut être restreint"
    }

    private var modelSourceText: String {
        if state.testing { return "Test en cours…" }
        guard let date = state.lastModelRefresh else {
            return "Modèles : listes déclarées. « Rafraîchir » interroge chaque provider."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Dernière synchronisation : \(formatter.string(from: date)). Données interrogées auprès des providers ; Codex expose ses propres slugs."
    }
    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.statusMessage {
                Label {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.07))
                )
            }

            HStack(spacing: 12) {
                Toggle("Mémoriser les clés localement", isOn: Binding(
                    get: { state.persistenceEnabled },
                    set: { on in on ? state.enablePersistence() : state.disablePersistence() }
                ))
                .font(.callout)
                .toggleStyle(.checkbox)
                .help("Fichier local avec permissions 0600, exclu d’iCloud")
                .disabled(state.isScreenshotMode)

                Spacer(minLength: 10)

                Button("Quitter") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private var trimmedKey: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var misroutedOpenRouterKey: Bool {
        trimmedKey.hasPrefix("sk-or-v1-")
            && (state.keyEditingProvider?.id != "openrouter")
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
        guard !trimmedKey.isEmpty, !misroutedOpenRouterKey else { return }
        let providerID = state.keyEditingProvider?.id
        Task { await state.setSessionKey(trimmedKey, for: providerID) }
        draftKey = ""
        state.dismissKeyEditor()
    }

    private func editKey(for provider: Provider) {
        NSApp.activate(ignoringOtherApps: true)
        draftKey = ""
        state.presentKeySheet(for: provider.id)
        focusKeyEditor()
    }

    private func editKey(for providerID: String) {
        NSApp.activate(ignoringOtherApps: true)
        draftKey = ""
        state.presentKeySheet(for: providerID)
        focusKeyEditor()
    }

    private func focusKeyEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
            keyFieldFocused = true
        }
    }

    /// Placeholder that hints at the format each provider expects: Z.ai keys are
    /// `ID.secret`, everything else in this app is `sk-…`.
    private var keyPlaceholder: String {
        guard let provider = state.keyEditingProvider else { return "sk-…" }
        if state.hasKey(for: provider.id) { return "Clé existante — tapez pour remplacer" }
        switch provider.id {
        case "glm": return "ID.secret (clé Z.ai, ex. 6e6c…54d8.xxxx)"
        case "opencode": return "sk-… (optionnelle — la clé Zen remplace le palier gratuit)"
        case "claude": return "sk-ant-… (optionnelle — sinon Claude Code/ANTHROPIC_AUTH_TOKEN)"
        default: return "sk-…"
        }
    }
}

// MARK: - Small UI primitives

private struct SectionHeader: View {
    let title: String
    let accessory: String?

    init(_ title: String, accessory: String? = nil) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)

            if let accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SecondaryInfoRow: View {
    let text: String
    let symbol: String
    let symbolColor: Color

    init(text: String, symbol: String, symbolColor: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.symbolColor = symbolColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(symbolColor)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
    @State private var isKeyHovered = false

    var body: some View {
        HStack(spacing: 0) {
            selectionButton
                .frame(maxWidth: .infinity)

            if !provider.isReserved {
                keyButton
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(cardBorder)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isKeyHovered)
        .accessibilityElement(children: .contain)
    }

    private var selectionButton: some View {
        Button(action: tap) {
            HStack(spacing: 9) {
                providerIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)
                activeIndicator
            }
            .padding(.leading, 10)
            .padding(.vertical, 9)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(provider.displayName), \(detailText)")
        .accessibilityHint(isActive ? "Provider actif" : "Activer ce provider")
        .help(isActive ? "Provider actif : \(provider.displayName)" : "Activer \(provider.displayName)")
        .disabled(isInteractionDisabled)
    }

    private var providerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(provider.brandColor.opacity(0.14))

            Image(systemName: provider.brandSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(provider.brandColor)
        }
        .frame(width: 27, height: 27)
    }

    @ViewBuilder
    private var activeIndicator: some View {
        if isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Provider actif")
        } else {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    private var keyButton: some View {
        Button(action: keyTap) {
            Image(systemName: hasKey ? "key.fill" : "key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hasKey ? Color.green : Color.secondary)
                .frame(width: 34, height: 42)
                .background(
                    Rectangle().fill(Color.primary.opacity(isKeyHovered ? 0.045 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isKeyHovered = $0 }
        .accessibilityLabel(hasKey ? "Modifier la clé \(provider.displayName)" : "Saisir la clé \(provider.displayName)")
        .help(hasKey ? "Modifier la clé \(provider.displayName)" : "Saisir la clé \(provider.displayName)")
        .disabled(isInteractionDisabled)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(
                isActive
                    ? Color.accentColor.opacity(0.085)
                    : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.94 : 1)
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
                isActive
                    ? Color.accentColor.opacity(0.62)
                    : Color.secondary.opacity(isHovered ? 0.20 : 0.10),
                lineWidth: 1
            )
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
