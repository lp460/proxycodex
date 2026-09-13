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
    @State private var journalExpanded = false
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
                    usageSection
                    keySection
                    launchSection
                    maintenanceSection
                    journalSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            // macOS 26 MenuBarExtra windows ignore the ScrollView's ideal height
            // and collapse to the fixed-size content only (header + footer). A
            // FIXED height keeps the viewport real.
            .frame(height: 620)
            Divider()
            footer
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: state.language.rawValue))
        .id(state.language)
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
                Text(L("AI Provider Switcher"))
                    .font(.system(size: 15, weight: .semibold))
                Text(activeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            languagePicker
            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    private var languagePicker: some View {
        HStack(spacing: 5) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    state.setLanguage(language)
                } label: {
                    Text(language.flag)
                        .font(.system(size: 14))
                        .frame(width: 27, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(state.language == language ? Color.accentColor.opacity(0.16) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    state.language == language ? Color.accentColor.opacity(0.50) : Color.secondary.opacity(0.14),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(state.language == language
                      ? L("Langue actuelle : %@", language.accessibilityName)
                      : L("Afficher en %@", language.accessibilityName))
                .accessibilityLabel(Text(language.accessibilityName))
                .accessibilityAddTraits(state.language == language ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Langue")))
    }

    private var activeSummary: String {
        let providerName = state.activeProvider?.displayName ?? L("Provider")
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
        .accessibilityLabel(L("État de la configuration"))
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
        case .incompatible: return L("Erreur")
        case .untested: return state.isActiveNative ? L("Native") : L("Non testé")
        }
    }

    // MARK: Providers (status + key badge per provider)

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Fournisseur"))
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
                text: L("Un clic applique la configuration et relance ChatGPT/Codex."),
                symbol: "info.circle"
            )
        }
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Modèle"))

            Picker(L("Modèle"), selection: Binding(
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
                    text: L("Codex voit « %@ » : contrat natif complet (outils, MCP, plugins).", exposed),
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
                    text: L("Le modèle par défaut et le modèle actif restent verrouillés."),
                    symbol: "lock.fill"
                )
            }
            .padding(.top, 8)
            .padding(.leading, 2)
        } label: {
            HStack {
                Text(L("Modèles exposés"))
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
                L("Catalogue Codex personnalisé détecté"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.orange)

            Text(L("La liste générée par Proxycodex n’est pas active."))
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.82))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .accessibilityLabel(L("Avertissement : catalogue Codex personnalisé détecté"))
    }

    // MARK: Quota & usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Quota & utilisation"))

            if let provider = state.activeProvider {
                UsageCard(
                    provider: provider,
                    snapshot: state.providerUsage[provider.id],
                    isRefreshing: state.refreshingUsageIDs.contains(provider.id),
                    errorMessage: state.usageErrors[provider.id],
                    refresh: {
                        Task { await state.refreshUsage(for: provider.id, force: true) }
                    }
                )
            }

            let miniProviders = state.catalog.providers.filter {
                $0.id != state.snapshot.activeProviderID
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 122, maximum: 160), spacing: 8)],
                spacing: 8
            ) {
                ForEach(miniProviders) { provider in
                    UsageMiniCard(
                        provider: provider,
                        snapshot: state.providerUsage[provider.id],
                        isRefreshing: state.refreshingUsageIDs.contains(provider.id)
                    )
                }
            }
        }
    }

    // MARK: Journal

    private var journalSection: some View {
        DisclosureGroup(isExpanded: $journalExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Journal"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Effacer")) { state.clearLogs() }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                }

                if state.logs.isEmpty {
                    Text(L("Aucun événement."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.logs.suffix(10).reversed())) { entry in
                        JournalRow(entry: entry)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text(L("Journal"))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(L("%lld événements", state.logs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .controlSize(.small)
    }

    // MARK: Keys

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.editingKey {
                SectionHeader(
                    L("Clé API"),
                    accessory: state.keyEditingProvider?.displayName
                )
            } else {
                SectionHeader(L("Clé API"))
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
        let providerName = state.activeProvider?.displayName ?? L("ce provider")
        if state.activeProvider?.isKeyless == true || state.isActiveNative {
            return L("Aucune clé requise")
        }
        return state.hasKeyForActive
            ? L("Clé enregistrée pour %@", providerName)
            : L("Aucune clé pour %@", providerName)
    }

    private var keyActionButtonTitle: String {
        state.activeProvider?.isKeyless == true || state.isActiveNative
            ? L("Modifier")
            : (state.hasKeyForActive ? L("Modifier") : L("Ajouter une clé"))
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
                Text(L("Cible : %@", provider.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(L("Coller")) { pasteKey() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if let provider = state.keyEditingProvider, state.hasKey(for: provider.id) {
                    Button(L("Voir la clé")) { showExistingKey() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Spacer(minLength: 8)

                Button(L("Annuler")) {
                    draftKey = ""
                    state.dismissKeyEditor()
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.secondary)

                Button(L("Injecter")) { injectKey() }
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
                    L("Format DeepSeek/OpenRouter détecté — une clé Z.ai est de la forme ID.secret."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !trimmed.isEmpty && !trimmed.contains(".") {
                Label(
                    L("Format attendu : ID.secret (la clé Z.ai contient un point)."),
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
                L("Clé OpenRouter détectée dans le champ %@. Utilisez la clé de la carte OpenRouter.", provider.displayName),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    // MARK: Launch

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(L("Ouvrir"))

            Button {
                state.launchCodexCLI()
            } label: {
                Label(L("Lancer Codex CLI"), systemImage: "terminal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(L("Lance Codex avec revue automatique des approbations (workspace-write) et la clé du provider actif"))
            .disabled(state.isScreenshotMode)

            Button {
                Task { await state.relaunchChatGPT() }
            } label: {
                Label(L("Relancer ChatGPT / Codex"), systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(L("Redémarre l'app ChatGPT pour appliquer les clés injectées au sélecteur de modèles"))
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
                            Label(L("Test en cours…"), systemImage: "hourglass")
                        } else {
                            Label(L("Tester tous"), systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.testing || state.isScreenshotMode)

                    Button {
                        Task { await state.refreshModels() }
                    } label: {
                        Label(
                            state.refreshingModels ? L("Lecture…") : L("Rafraîchir les modèles"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L("Demande à chaque provider la liste des modèles qu'il sert réellement"))
                    .disabled(state.refreshingModels || state.isScreenshotMode)

                    Button {
                        Task { await state.refreshAllUsage() }
                    } label: {
                        Label(L("Actualiser tous les quotas"), systemImage: "gauge.with.needle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isScreenshotMode || !state.refreshingUsageIDs.isEmpty)
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
                Text(L("Maintenance"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()
                Text(L("Diagnostics"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .controlSize(.small)
    }

    private var openCodeStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("OpenCode"))
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
            return L("CLI non détectée · saisissez une clé Zen, ou exécutez `opencode auth login`")
        }

        let version = install.version.map { "CLI \($0)" } ?? "CLI"
        if state.hasKey(for: "opencode") {
            let go = state.hasKey(for: "opencode-go") ? L(" · clé Go enregistrée") : ""
            return "\(version) " + L("détectée") + " · " + L("clé Zen enregistrée") + go
        }
        let zen = install.hasZenCredential ? L("clé Zen réutilisée") : L("pas de clé Zen")
        let go = state.hasKey(for: "opencode-go") ? L("clé Go enregistrée") : L("pas de clé Go")
        return "\(version) " + L("détectée") + " · \(zen) · \(go)"
    }

    private var modelSourceText: String {
        if state.testing { return L("Test en cours…") }
        guard let date = state.lastModelRefresh else {
            return L("Modèles : listes déclarées. « Rafraîchir » interroge chaque provider.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return L("Dernière synchronisation : %@. Données interrogées auprès des providers ; Codex expose ses propres slugs.", formatter.string(from: date))
    }
    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.statusMessage {
                Label {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
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
                Toggle(L("Mémoriser les clés localement"), isOn: Binding(
                    get: { state.persistenceEnabled },
                    set: { on in on ? state.enablePersistence() : state.disablePersistence() }
                ))
                .font(.callout)
                .toggleStyle(.checkbox)
                .help(L("Fichier local avec permissions 0600, exclu d’iCloud"))
                .disabled(state.isScreenshotMode)

                Spacer(minLength: 10)

                Button(L("Quitter")) { NSApplication.shared.terminate(nil) }
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
        let key = trimmedKey
        let providerID = state.keyEditingProvider?.id
        guard !key.isEmpty, !misroutedOpenRouterKey else { return }
        draftKey = ""
        Task { await state.setSessionKey(key, for: providerID) }
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
        if state.hasKey(for: provider.id) { return L("Clé existante — tapez pour remplacer") }
        switch provider.id {
        case "glm": return L("ID.secret (clé Z.ai, ex. 6e6c…54d8.xxxx)")
        case "opencode": return L("sk-… (optionnelle — la clé Zen remplace le palier gratuit)")
        case "opencode-go": return L("sk-… (clé Go — requise, abonnement OpenCode Go)")
        case "claude": return L("sk-ant-… (optionnelle — sinon Claude Code/ANTHROPIC_AUTH_TOKEN)")
        default: return "sk-…"
        }
    }
}

// MARK: - Small UI primitives

private struct UsageCard: View {
    let provider: Provider
    let snapshot: ProviderUsageSnapshot?
    let isRefreshing: Bool
    let errorMessage: String?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.callout.weight(.semibold))
                    if let plan = snapshot?.planLabel {
                        Text(L(plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    refresh()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(isRefreshing ? Color.secondary : Color.accentColor)
                        Text(isRefreshing ? L("Actualisation…") : L("Actualiser"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
            }

            if let snapshot {
                snapshotContent(snapshot)

                if !isRefreshing, snapshot.hasUsefulData, let errorMessage {
                    Label {
                        Text(L("%@ · dernière donnée conservée.", errorMessage))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                HStack(spacing: 4) {
                    Text(L("Mis à jour"))
                        .foregroundStyle(.secondary)
                    Text(snapshot.fetchedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
            } else if isRefreshing {
                Label(L("Actualisation…"), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Quota indisponible"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: ProviderUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let balance = snapshot.balance {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(
                        balance.available == nil && balance.used != nil
                            ? "Consommation connue"
                            : balance.label
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(UsageFormatting.currency(balance.available ?? balance.used, code: balance.currency))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let detail = UsageFormatting.balanceDetail(balance) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(snapshot.windows) { window in
                UsageWindowRow(window: window)
            }

            if !snapshot.windows.isEmpty || snapshot.balance != nil {
                if let note = snapshot.note, !note.isEmpty {
                    Text(L(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.statusTitle(snapshot.status))
                        .font(.callout.weight(.medium))
                    if let note = snapshot.note ?? Self.statusNote(snapshot.status) {
                        Text(L(note))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func statusTitle(_ status: ProviderUsageStatus) -> String {
        switch status {
        case .authenticationRequired: return L("Clé requise")
        case .unsupported: return L("Non exposé")
        case .unavailable: return L("Indisponible")
        case .failed: return L("Impossible d'actualiser")
        case .available: return L("Aucune donnée")
        }
    }

    private static func statusNote(_ status: ProviderUsageStatus) -> String? {
        switch status {
        case .authenticationRequired: return L("Ajoutez la clé provider pour lire le quota.")
        case .unavailable: return L("Le provider n'a pas fourni de valeur utilisable.")
        case .failed: return L("Dernière donnée conservée si disponible ; détail dans le journal.")
        case .unsupported, .available: return nil
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(window.label))
                    .font(.callout.weight(.medium))
                Spacer()
                Text(remainingText)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }

            UsageProgressBar(remainingPercent: window.remainingPercent)

            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remainingText: String {
        guard let remaining = window.remainingPercent else { return "—" }
        return L("%lld %% restant", Int(remaining.rounded()))
    }

    private var color: Color {
        guard let remaining = window.remainingPercent else { return .secondary }
        if remaining >= 50 { return .green }
        if remaining >= 20 { return .orange }
        return .red
    }

    private var resetText: String {
        if let reset = window.resetsAt {
            let interval = reset.timeIntervalSinceNow
            if interval > 0 {
                return L("Reset %@ · %@", UsageFormatting.relativeCountdown(reset), UsageFormatting.clock(reset))
            }
            return L("Reset %@", UsageFormatting.clock(reset))
        }
        return L(window.detail ?? "Reset non exposé")
    }
}

private struct UsageProgressBar: View {
    let remainingPercent: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Quota restant"))
        .accessibilityValue(remainingText)
    }

    private var fraction: Double {
        min(1, max(0, (remainingPercent ?? 0) / 100))
    }

    private var color: Color {
        guard let value = remainingPercent else { return .secondary }
        if value >= 50 { return .green }
        if value >= 20 { return .orange }
        return .red
    }

    private var remainingText: String {
        guard let remainingPercent else { return L("inconnu") }
        return "\(Int(remainingPercent.rounded())) %"
    }
}

private struct UsageMiniCard: View {
    let provider: Provider
    let snapshot: ProviderUsageSnapshot?
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(provider.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isRefreshing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(snapshot?.hasUsefulData == true ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let remaining = snapshot?.windows.compactMap(\.remainingPercent).first {
                UsageProgressBar(remainingPercent: remaining)
            } else if snapshot?.balance?.available != nil {
                UsageProgressBar(remainingPercent: balancePercent)
            } else {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 5)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    private var balancePercent: Double? {
        guard let available = snapshot?.balance?.available,
              let total = snapshot?.balance?.total,
              total > 0 else { return nil }
        return max(0, min(100, NSDecimalNumber(decimal: available).doubleValue / NSDecimalNumber(decimal: total).doubleValue * 100))
    }

    private var summary: String {
        guard let snapshot else { return L("Aucune donnée") }
        if let window = snapshot.windows.first, let remaining = window.remainingPercent {
            return L("%lld %% · %@", Int(remaining.rounded()), L(window.label))
        }
        if let available = snapshot.balance?.available {
            return UsageFormatting.currency(available, code: snapshot.balance?.currency ?? "USD")
        }
        switch snapshot.status {
        case .authenticationRequired: return L("Clé requise")
        case .unsupported: return provider.id == "ollama" ? L("Local") : L("Non exposé")
        case .unavailable, .failed: return L("Indisponible")
        case .available: return snapshot.note?.isEmpty == false ? L(snapshot.note!) : L("Aucune donnée")
        }
    }
}

private struct JournalRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(UsageFormatting.time(entry.date))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(entry.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

enum UsageFormatting {
    static func currency(_ value: Decimal?, code: String) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = .current
        if code.uppercased() == "USD" {
            formatter.currencySymbol = "$"
        }
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value) \(code)"
    }

    static func balanceDetail(_ balance: UsageBalance) -> String? {
        var parts: [String] = []
        if let toppedUp = balance.toppedUp {
            parts.append(L("%@ rechargés", currency(toppedUp, code: balance.currency)))
        }
        if let granted = balance.granted {
            parts.append(L("%@ offerts", currency(granted, code: balance.currency)))
        }
        if let total = balance.total {
            parts.append(L("sur %@", currency(total, code: balance.currency)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if Calendar.current.isDateInTomorrow(date) {
            return L("demain %@", formatter.string(from: date))
        }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .weekOfYear) {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return L("%1$@ %2$@", formatter.string(from: date), shortTime.string(from: date))
        }
        return shortTime.string(from: date)
    }

    private static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static func relativeCountdown(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: .now, to: date)
        if let day = components.day, day > 0 {
            return L("dans %1$lld j %2$lld h", day, components.hour ?? 0)
        }
        if let hour = components.hour, hour > 0 {
            return L("dans %1$lld h %2$lld min", hour, components.minute ?? 0)
        }
        return L("dans %lld min", max(0, components.minute ?? 0))
    }
}

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
        .accessibilityHint(isActive ? L("Provider actif") : L("Activer ce provider"))
        .help(isActive ? L("Provider actif : %@", provider.displayName) : L("Activer %@", provider.displayName))
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
                .accessibilityLabel(L("Provider actif"))
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
        .accessibilityLabel(hasKey ? L("Modifier la clé %@", provider.displayName) : L("Saisir la clé %@", provider.displayName))
        .help(hasKey ? L("Modifier la clé %@", provider.displayName) : L("Saisir la clé %@", provider.displayName))
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
        if !hasKey && provider.requiresKey { return L("Clé manquante") }
        switch status {
        case .compatible: return L("Connecté")
        case .incompatible(let reason): return L("Erreur · %@", reason)
        case .untested: return L("Non testé")
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
