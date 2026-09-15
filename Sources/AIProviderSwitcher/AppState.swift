import Foundation
import SwiftUI
import AppKit
import Darwin
import CryptoKit
import AIProviderSwitcherCore

/// Observable application state. Purely additive over `~/.codex`:
///
/// - **Install (once):** `CodexConfigStore.install` appends `[model_providers.<id>]`
///   blocks and writes profile files. The native OpenAI config is never modified.
/// - **Select:** for Desktop/IDE, `applyOverride` edits only the top-level
///   `model`/`model_provider` (reversible); OpenAI = `revertOverride` (native).
/// - **Codex CLI:** launched with `--profile <id>` + env-key, or bare for OpenAI.
/// One line of the in-app activity log shown in the panel.
struct LogEntry: Identifiable, Equatable {
    let id: Int
    let date: Date
    let message: String
}

@MainActor
final class AppState: ObservableObject {

    /// Providers, with model lists refreshed from what each provider answers.
    @Published private(set) var catalog = ProviderCatalog.default
    let keyStore = KeyStore()
    let checker = CompatibilityChecker(localize: { L($0) })
    let configStore = CodexConfigStore()
    let discovery = ModelDiscovery()
    let discoveredStore = DiscoveredModelStore(url: DiscoveredModelStore.defaultURL())
    let selectionStore = ModelSelectionStore(url: ModelSelectionStore.defaultURL())
    let usageService = ProviderUsageService(timeout: 6, localize: { L($0) })
    /// Passive Multi-Agent compatibility: learned from the adapter proxy's
    /// structured observations, never from a launched probe.
    let capabilityStore = MultiAgentCapabilityStore(url: MultiAgentCapabilityStore.defaultURL())
    let capabilityLog = MultiAgentEventLog(url: MultiAgentEventLog.defaultURL())
    private var discovered: [String: DiscoveredModels] = [:]
    /// Per-provider subset of models exposed through Codex's finite native
    /// slugs, as chosen by the user. Absent = keep the provider's first models.
    private var modelSelection: [String: [String]] = [:]

    private(set) var router: ProviderRouter?
    private let screenshotMode: Bool
    private let screenshotKeyIDs: Set<String> = ["deepseek", "glm", "openrouter"]

    @Published var snapshot = RouterSnapshot(activeProviderID: "openai", activeModel: "gpt-5.6")
    @Published var statusMessage: String?
    @Published var testing = false
    @Published var chatGPTRunning = false
    @Published var persistenceEnabled = false
    @Published var nativeConfigDetected = false
    @Published var providersInstalled = false
    @Published var catalogConflict = false
    @Published var editingKey = false
    @Published var editingProviderID: String?
    /// OpenCode CLI found on this machine, if any. Informational: the Zen
    /// gateway the provider talks to works without the CLI.
    @Published var openCode: OpenCodeInstallation?
    @Published var refreshingModels = false
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var providerUsage: [String: ProviderUsageSnapshot] = [:]
    @Published private(set) var refreshingUsageIDs: Set<String> = []
    @Published private(set) var lastUsageRefresh: Date?
    @Published private(set) var usageErrors: [String: String] = [:]
    @Published private(set) var language = LocalizationManager.language
    /// Codex Multi-Agent V2 as read from `config.toml` (read-only until the user
    /// acts in the panel; a hand-written entry stays the user's own).
    @Published private(set) var multiAgentConfig = CodexMultiAgentConfig.absent()
    @Published var applyingMultiAgentConfig = false
    /// Set when `config.toml` could not be read; the panel then says so instead
    /// of pretending the feature is simply off.
    @Published private(set) var multiAgentReadError: String?
    /// Per `providerID + modelID` Multi-Agent evidence, as observed in real
    /// sessions. Refreshed from the proxy's event log; never probed.
    @Published private(set) var capabilityRecords: [String: ModelCapabilityRecord] = [:]
    /// Cached `codex --version`, read at most once per launch.
    @Published private(set) var codexVersion: String?

    private var observationTask: Task<Void, Never>?
    private var capabilityTask: Task<Void, Never>?
    private var lastEventLogSize: UInt64 = 0
    private var nextLogID = 1
    private let maxLogs = 100
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configFixTask: Task<Void, Never>?
    /// Set when a provider card click asked for a key that was missing: the
    /// next successful injection for that provider applies the selection and
    /// relaunches Codex, so the user never has to click the card a second time.
    private var applySelectionAfterKeyInjection = false
    private var applySelectionTargetID: String?
    private var usageRefreshTasks: [String: Task<Void, Never>] = [:]

    init() {
        screenshotMode = CommandLine.arguments.contains("--panel-screenshot")

        if screenshotMode {
            // Deterministic, secret-free demo state used only to refresh the
            // README screenshots. It never touches ~/.codex or the key file.
            snapshot = RouterSnapshot(
                activeProviderID: "deepseek",
                activeModel: "deepseek-v4-flash",
                compatibilities: [
                    "openai": .compatible,
                    "deepseek": .compatible,
                    "glm": .compatible,
                    "openrouter": .untested,
                    "ollama": .compatible,
                    "claude": .compatible,
                    "opencode": .compatible,
                    "opencode-go": .compatible
                ]
            )
            openCode = OpenCodeInstallation(
                executable: URL(fileURLWithPath: "/Users/demo/.opencode/bin/opencode"),
                version: "1.18.21",
                hasZenCredential: false
            )
            if let opencode = ProviderCatalog.default[id: "opencode"] {
                modelSelection["opencode"] = Array(opencode.models.prefix(6))
            }
            if let opencodeGo = ProviderCatalog.default[id: "opencode-go"] {
                modelSelection["opencode-go"] = Array(opencodeGo.models.prefix(6))
            }
            router = try? ProviderRouter(
                catalog: catalog,
                keyResolver: keyStore,
                initialProviderID: "deepseek"
            )
            nativeConfigDetected = true
            providersInstalled = true
            statusMessage = L("Démonstration prête · aucun secret réel utilisé.")
            // Deterministic demo state for the README capture: enabled, 8
            // threads, owned by Proxycodex. Nothing is read from ~/.codex.
            multiAgentConfig = CodexMultiAgentConfig(
                enabled: true,
                maxConcurrentThreads: CodexMultiAgentConfig.defaultThreads,
                source: .proxycodexManaged
            )
            // Deterministic compatibility example: a model that really ran a
            // sub-agent cycle in a past session. No network, no file read.
            loadScreenshotCapabilities()
            loadScreenshotUsage()
        } else {
            // Keep keys across restarts: persistence is ON by default (0600 file,
            // excluded from iCloud). Keys are loaded back into memory at launch so
            // they never have to be re-entered; the footer toggle can disable it.
            _ = try? keyStore.enablePersistence(at: KeyStore.defaultPersistentURL())
            persistenceEnabled = keyStore.persistenceEnabled
            _ = try? keyStore.loadFromDisk()
            modelSelection = selectionStore.load()
            // Build the router/detect native config as soon as the app launches, so the
            // menu actions (select, key, launch) are wired before the user clicks.
            Task { await self.bootstrap() }
        }

        // `--panel-screenshot` shows the real panel in a window so it can be
        // captured for the README (no menu bar interaction required).
        if screenshotMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let host = NSHostingController(rootView: PanelView(state: self))
                let win = NSWindow(contentViewController: host)
                win.styleMask = [.titled, .closable]
                win.appearance = NSAppearance(named: .darkAqua)
                win.title = "AI Provider Switcher"
                win.setContentSize(NSSize(width: 556, height: 820))
                win.center()
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: Logging (kept in-memory; drives the status line + journal)

    func log(_ message: String) {
        let entry = LogEntry(id: nextLogID, date: Date(), message: message)
        nextLogID += 1
        logs.append(entry)
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
        statusMessage = message
    }

    func clearLogs() {
        logs.removeAll()
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        LocalizationManager.language = newLanguage
        language = newLanguage
    }

    // MARK: Quota & usage

    // MARK: Passive Multi-Agent compatibility

    /// How a provider reaches Codex, which decides what a status can mean.
    /// OpenAI speaks Codex's native protocol; Ollama is implemented by Codex
    /// itself without an adapter; everything else goes through the bridge.
    func supportPath(for providerID: String) -> MultiAgentSupportPath {
        if providerID == "openai" { return .nativeCodex }
        return CodexConfigGenerator.proxyPort(for: providerID) == nil ? .unbridged : .bridged
    }

    /// Observed compatibility for one provider+model. Nothing is inferred from
    /// the model's name or from the provider's claimed capabilities.
    func multiAgentCompatibility(for providerID: String, model: String) -> MultiAgentCompatibility {
        let key = ModelCapabilityRecord(providerID: providerID, modelID: model).key
        return MultiAgentCompatibility(
            path: supportPath(for: providerID),
            record: capabilityRecords[key]?.multiAgent
        )
    }

    /// Observed compatibility for what Codex is currently talking to.
    var activeMultiAgentCompatibility: MultiAgentCompatibility {
        multiAgentCompatibility(for: snapshot.activeProviderID, model: snapshot.activeModel)
    }

    /// Watches the proxy's observation log. A local file read, on a slow timer:
    /// it never contacts a provider and adds no request to a session.
    private func startCapabilityObservation() {
        guard !screenshotMode, capabilityTask == nil else { return }
        capabilityTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ingestMultiAgentObservations()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    /// Reads what the proxies observed since the last pass. The log is only
    /// touched when its size changed, so the steady-state cost is one `stat`.
    func ingestMultiAgentObservations() async {
        guard !screenshotMode, capabilityLog.exists() else { return }
        let size = capabilityLog.currentSize()
        guard size > 0, size != lastEventLogSize else { return }
        let events = capabilityLog.drain()
        lastEventLogSize = capabilityLog.currentSize()
        guard !events.isEmpty else { return }
        let version: String?
        if let known = codexVersion {
            version = known
        } else {
            version = await resolveCodexVersion()
        }
        let changes = await capabilityStore.apply(events, codexVersion: version)
        capabilityRecords = Dictionary(
            uniqueKeysWithValues: await capabilityStore.all().map { ($0.key, $0) })
        for change in changes {
            log(multiAgentLogMessage(for: change))
        }
    }

    /// What the journal says about a status transition. Technical vocabulary
    /// stays out of it: the user reads "validé", not "namespace restored".
    private func multiAgentLogMessage(for change: MultiAgentCapabilityChange) -> String {
        let model = change.modelID
        let reason = L(MultiAgentFailureReason(code: change.reason).localizationKey)
        if change.current == change.previous {
            // No status movement: new information only. An established
            // conclusion, if any, is preserved.
            return L("Multi-Agent · %@ : compatibilité conservée · essai non concluant · %@.",
                     model, reason)
        }
        switch change.current {
        case .validated:
            return L("Multi-Agent · %@ : sous-agent créé avec succès · compatibilité validée.", model)
        case .observed:
            return L("Multi-Agent · %@ : première utilisation observée.", model)
        case .inconclusive:
            return L("Multi-Agent · %@ : essai non concluant · %@.", model, reason)
        case .incompatible:
            return L("Multi-Agent · %@ : non compatible (%@).", model, reason)
        case .stale:
            return L("Multi-Agent · %@ : validation à revalider à la prochaine utilisation.", model)
        case .unknown:
            return L("Multi-Agent · %@ : aucune observation pour l’instant.", model)
        }
    }

    /// `codex --version`, run at most once per launch and cached.
    private func resolveCodexVersion() async -> String? {
        if let codexVersion { return codexVersion }
        guard let executable = AppState.findCodexExecutable() else { return nil }
        let version = await Task.detached(priority: .utility) {
            CodexVersionProbe.version(of: executable)
        }.value
        codexVersion = version
        return version
    }

    /// Background refresh, with a small in-memory TTL. A quota problem never
    /// invalidates model routing or provider compatibility.
    func refreshUsage(for providerID: String, force: Bool = false) async {
        guard !screenshotMode, catalog[id: providerID] != nil, usageRefreshTasks[providerID] == nil else {
            return
        }
        if let snapshot = providerUsage[providerID], !force,
           Date().timeIntervalSince(snapshot.fetchedAt) < 90 {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUsageRefresh(for: providerID)
        }
        usageRefreshTasks[providerID] = task
        refreshingUsageIDs.insert(providerID)
        defer {
            usageRefreshTasks[providerID] = nil
            refreshingUsageIDs.remove(providerID)
        }
        await task.value
    }

    private func performUsageRefresh(for providerID: String) async {
        guard let provider = catalog[id: providerID] else { return }
        do {
            let snapshot: ProviderUsageSnapshot
            if providerID == "openai" {
                guard let executable = AppState.findCodexExecutable() else {
                    throw MissingCodexError()
                }
                snapshot = try await usageService.codexSnapshot(executable: executable)
            } else {
                snapshot = try await usageService.snapshot(
                    for: provider,
                    secret: keyStore.secret(for: provider.id)
                )
            }
            providerUsage[providerID] = snapshot
            lastUsageRefresh = Date()
            usageErrors[providerID] = nil
            log(usageLogMessage(snapshot))
        } catch {
            let rawDescription = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            let description = L(rawDescription)
            if providerUsage[providerID] == nil {
                providerUsage[providerID] = ProviderUsageSnapshot(
                    providerID: providerID,
                    status: .failed(description)
                )
            }
            usageErrors[providerID] = description
            log(L(
                "Échec lecture quota %@ : %@. Dernière donnée conservée si disponible.",
                provider.displayName,
                description
            ))
        }
    }

    func refreshActiveUsage(force: Bool = false) async {
        await refreshUsage(for: snapshot.activeProviderID, force: force)
    }

    func refreshAllUsage() async {
        for provider in catalog.providers {
            await refreshUsage(for: provider.id, force: false)
        }
    }

    private func usageLogMessage(_ snapshot: ProviderUsageSnapshot) -> String {
        let provider = catalog[id: snapshot.providerID]?.displayName ?? snapshot.providerID
        if let balance = snapshot.balance {
            if snapshot.providerID == "deepseek" {
                return L("Solde %@ · %@ %@ disponibles.", provider, formatQuota(balance.available), balance.currency)
            }
            return L("Budget %@ · %@ %@ restants.", provider, formatQuota(balance.available), balance.currency)
        }
        if snapshot.windows.isEmpty {
            switch snapshot.status {
            case .unsupported:
                return L("Quota %@ non exposé par une API supportée.", provider)
            case .authenticationRequired:
                return L("Quota %@ : clé requise.", provider)
            case .unavailable:
                return L("Quota %@ indisponible.", provider)
            case .failed(let reason):
                return L("Échec lecture quota %@ : %@.", provider, reason)
            case .available:
                return L("Quota %@ : aucune donnée exposée.", provider)
            }
        }
        let details = snapshot.windows.map { window -> String in
            guard let remaining = window.remainingPercent else {
                return L(window.label)
            }
            return L("%@ : %lld %% restant", L(window.label), Int(remaining.rounded()))
        }
        return L("Quota %@ · %@.", provider, details.joined(separator: " · "))
    }

    private func formatQuota(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    private struct MissingCodexError: LocalizedError {
        var errorDescription: String? { "Codex CLI introuvable." }
    }

    /// Screenshot-only capability state: deterministic, secret-free, and never
    /// written to disk. Mirrors what a real validated session looks like.
    private func loadScreenshotCapabilities() {
        let validatedAt = Date().addingTimeInterval(-3_600)
        let records = [
            ModelCapabilityRecord(
                providerID: "openai", modelID: "gpt-5.6",
                multiAgent: MultiAgentCapabilityRecord(status: .unknown)),
            ModelCapabilityRecord(
                providerID: "deepseek", modelID: "deepseek-v4-flash",
                multiAgent: MultiAgentCapabilityRecord(
                    status: .validated, validatedAt: validatedAt,
                    lastObservedAt: validatedAt, codexVersion: "0.154.0-alpha.6.2",
                    bridgeVersion: MultiAgentCapabilityStore.bridgeCapabilityVersion)),
            ModelCapabilityRecord(
                providerID: "opencode-go", modelID: "grok-4.6",
                multiAgent: MultiAgentCapabilityRecord(
                    status: .validated, validatedAt: validatedAt,
                    lastObservedAt: validatedAt, codexVersion: "0.154.0-alpha.6.2",
                    bridgeVersion: MultiAgentCapabilityStore.bridgeCapabilityVersion)),
            ModelCapabilityRecord(
                providerID: "openrouter", modelID: "openrouter/free",
                multiAgent: MultiAgentCapabilityRecord(
                    status: .inconclusive, lastObservedAt: validatedAt,
                    reason: "rate_limited")),
            ModelCapabilityRecord(
                providerID: "glm", modelID: "glm-5.3",
                multiAgent: MultiAgentCapabilityRecord(
                    status: .stale, validatedAt: validatedAt, lastObservedAt: validatedAt,
                    bridgeVersion: MultiAgentCapabilityStore.bridgeCapabilityVersion - 1))
        ]
        capabilityRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        codexVersion = "0.154.0-alpha.6.2"
    }

    private func loadScreenshotUsage() {
        let now = Date()
        providerUsage = [
            "openai": ProviderUsageSnapshot(
                providerID: "openai",
                fetchedAt: now,
                status: .available,
                windows: [
                    UsageWindow(id: "openai-5h", label: L("5 heures"), usedPercent: 22, durationMinutes: 300, resetsAt: now.addingTimeInterval(6_120)),
                    UsageWindow(id: "openai-week", label: L("7 jours"), usedPercent: 46, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(172_800))
                ]
            ),
            "deepseek": ProviderUsageSnapshot(
                providerID: "deepseek",
                fetchedAt: now,
                status: .available,
                balance: UsageBalance(
                    available: Decimal(string: "18.42"),
                    granted: Decimal(string: "2.00"),
                    toppedUp: Decimal(string: "16.42"),
                    currency: "USD",
                    label: L("Crédit API")
                )
            ),
            "glm": ProviderUsageSnapshot(
                providerID: "glm",
                fetchedAt: now,
                status: .available,
                planLabel: "Coding Plan",
                windows: [UsageWindow(id: "glm-5h", label: L("5 heures"), usedPercent: 72, durationMinutes: 300)]
            ),
            "openrouter": ProviderUsageSnapshot(
                providerID: "openrouter",
                fetchedAt: now,
                status: .available,
                balance: UsageBalance(
                    available: Decimal(string: "32.70"),
                    total: Decimal(string: "50"),
                    currency: "USD",
                    label: L("Budget de la clé")
                ),
                note: L("Reset : mensuel")
            ),
            "claude": ProviderUsageSnapshot(providerID: "claude", fetchedAt: now, status: .unsupported),
            "opencode": ProviderUsageSnapshot(providerID: "opencode", fetchedAt: now, status: .unsupported),
            "opencode-go": ProviderUsageSnapshot(
                providerID: "opencode-go",
                fetchedAt: now,
                status: .unsupported,
                note: L("Quota Go non exposé ici ; consultez la console OpenCode.")
            ),
            "ollama": ProviderUsageSnapshot(providerID: "ollama", fetchedAt: now, status: .available, note: L("Local · sans quota fournisseur."))
        ]
        let demoMessages = [
            L("DeepSeek sélectionné."),
            L("Modèles rafraîchis."),
            L("Solde DeepSeek · 18,42 USD disponibles."),
            L("Multi-Agent V2 activé · %lld threads maximum.", CodexMultiAgentConfig.defaultThreads),
            L("Codex CLI lancé.")
        ]
        for (offset, message) in demoMessages.enumerated() {
            let entry = LogEntry(id: offset + 1, date: now.addingTimeInterval(Double(offset - 4) * 28), message: message)
            logs.append(entry)
        }
        nextLogID = demoMessages.count + 1
        statusMessage = L("Démonstration prête · aucun secret réel utilisé.")
    }

    // MARK: Codex Multi-Agent V2 (additive: only its own marked block)

    /// Reads `[features.multi_agent_v2]` from `config.toml`.
    ///
    /// Never blocks the bootstrap: a malformed file is reported in the journal
    /// and the panel keeps its last known state.
    func refreshMultiAgentConfig(announce: Bool = false) {
        guard !screenshotMode else { return }
        do {
            let config = try configStore.readMultiAgentConfig()
            multiAgentReadError = nil
            multiAgentConfig = config
            if announce, config.isUserManaged {
                log(L(
                    "Configuration Multi-Agent externe détectée · %lld threads.",
                    config.maxConcurrentThreads
                ))
            }
        } catch {
            let description = error.localizedDescription
            multiAgentReadError = description
            log(L("Multi-Agent : configuration illisible (%@)", description))
        }
    }

    /// Turns Multi-Agent V2 on (first activation: the recommended 8 threads) or
    /// off. Disabling keeps the block with `enabled = false`, so the setting
    /// stays reversible and the thread count is remembered.
    func setMultiAgentEnabled(_ enabled: Bool) {
        guard !screenshotMode, !multiAgentConfig.isUserManaged else { return }
        applyMultiAgent(enabled: enabled, threads: multiAgentConfig.maxConcurrentThreads) { config in
            enabled
                ? L("Multi-Agent V2 activé · %lld threads maximum.", config.maxConcurrentThreads)
                : L("Multi-Agent V2 désactivé.")
        }
    }

    /// Sets the session thread count (main agent included) and enables the
    /// feature: a limit without delegation would have no effect.
    func setMultiAgentThreads(_ threads: Int) {
        guard !screenshotMode, !multiAgentConfig.isUserManaged else { return }
        let resolved = Self.clampedMultiAgentThreads(threads)
        guard resolved != multiAgentConfig.maxConcurrentThreads || !multiAgentConfig.enabled else { return }
        applyMultiAgent(enabled: true, threads: resolved) { config in
            L("Concurrence Multi-Agent réglée sur %lld threads.", config.maxConcurrentThreads)
        }
    }

    /// Applies a preset. `.custom` keeps the current value: the panel's numeric
    /// field then drives ``setMultiAgentThreads(_:)``.
    func setMultiAgentPreset(_ preset: MultiAgentPreset) {
        guard let threads = preset.threadCount else { return }
        setMultiAgentThreads(threads)
    }

    /// UI ceiling: the store accepts more, but the panel never writes a value it
    /// would not recommend.
    static func clampedMultiAgentThreads(_ threads: Int) -> Int {
        min(
            max(threads, CodexMultiAgentConfig.minimumThreads),
            CodexMultiAgentConfig.recommendedMaximumThreads
        )
    }

    private func applyMultiAgent(
        enabled: Bool,
        threads: Int,
        message: (CodexMultiAgentConfig) -> String
    ) {
        applyingMultiAgentConfig = true
        defer { applyingMultiAgentConfig = false }
        // Codex reads config.toml when a session starts; the watcher must never
        // treat the app's own write as an external change.
        stopConfigWatcher()
        defer { startConfigWatcher() }
        do {
            let written = try configStore.setMultiAgentConfig(enabled: enabled, threads: threads)
            multiAgentConfig = written
            multiAgentReadError = nil
            log(message(written))
        } catch {
            let description = error.localizedDescription
            multiAgentReadError = description
            log(L("Impossible de mettre à jour Multi-Agent : %@", description))
            // Resynchronise: the file may have been taken over by the user.
            refreshMultiAgentConfig()
        }
    }

    /// Opens `config.toml` — or `~/.codex` when it does not exist yet — with the
    /// system's default editor. Never forces a specific one.
    func openConfigToml() {
        guard !screenshotMode else { return }
        let url = configStore.paths.configToml
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Shortest quota window of the active provider, falling back to the
    /// Codex-native one: delegation happens inside a Codex session, so that
    /// reading stays the relevant one when a routed provider is active.
    var multiAgentQuotaRemainingPercent: Double? {
        shortestRemainingPercent(for: snapshot.activeProviderID)
            ?? shortestRemainingPercent(for: "openai")
    }

    private func shortestRemainingPercent(for providerID: String) -> Double? {
        guard let usage = providerUsage[providerID],
              usage.status != .unsupported,
              usage.status != .authenticationRequired else { return nil }
        return usage.windows
            .filter { $0.remainingPercent != nil }
            .min { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }?
            .remainingPercent
    }

    /// Recommendation only — the user's setting is never changed behind them.
    var multiAgentQuotaAdvice: MultiAgentQuotaAdvice {
        MultiAgentQuotaAdvice(remainingPercent: multiAgentQuotaRemainingPercent)
    }

    // MARK: Bootstrap (read-only detection — never modifies native config)

    func bootstrap() async {
        guard router == nil else { return }
        nativeConfigDetected = FileManager.default.fileExists(atPath: configStore.paths.configToml.path)
        // Resume from any override we previously applied; else default to OpenAI (native).
        let initial: String
        let model: String
        if let override = configStore.overrideState() {
            initial = override.provider
            model = override.model
        } else {
            initial = "openai"
            model = ProviderCatalog.default[id: "openai"]?.defaultModel ?? "gpt-5.6"
        }
        // Last known model lists, so a relaunch starts where discovery left off.
        applyDiscovered(discoveredStore.load())
        // Keys already granted to OpenCode are reused instead of re-asked.
        importKeysFromOpenCode()
        do {
            let router = try ProviderRouter(catalog: catalog, keyResolver: keyStore, initialProviderID: initial)
            _ = try await router.setActive(providerID: initial, model: model)
            self.router = router
            self.snapshot = await router.currentSnapshot()
            observationTask = Task { [weak self] in await self?.observeRouter() }
            providersInstalled = self.computeInstalled()
            // Always refresh provider blocks (keeps the local proxy base_urls
            // current) and the static model catalog.
            installProviders()
            ensureProxiesRunning()
            startConfigWatcher()
            log(nativeConfigDetected
                ? L("Codex natif détecté (%@).", configStore.paths.codexHome.path)
                : L("Aucun ~/.codex/config.toml ; lancez Codex une fois, puis « Installer les providers »."))
            // Multi-Agent V2 lives in config.toml too: read it once here, and
            // never let a malformed file abort the rest of the bootstrap.
            refreshMultiAgentConfig(announce: true)
            // Compatibility evidence already recorded by earlier sessions.
            _ = await capabilityStore.load()
            capabilityRecords = Dictionary(
                uniqueKeysWithValues: await capabilityStore.all().map { ($0.key, $0) })
            startCapabilityObservation()
        } catch {
        log(L("Init error: %@", error.localizedDescription))
        }
        refreshRunningApps()
        await detectOpenCode()
        log(L("Catalogue chargé : %@.", catalog.providers.map(\.displayName).joined(separator: ", ")))
        // Proxies are up now, so the providers can be asked what they serve.
        await refreshModels(announce: false)
        // Quota endpoints can be slower than startup; this stays behind the
        // completed bootstrap and never blocks provider switching.
        await refreshAllUsage()
    }

    // MARK: Model discovery

    /// Asks every provider for its current model list. Declared lists go stale
    /// as providers ship new models, so this is what makes a freshly released
    /// model appear without a new build.
    func refreshModels(announce: Bool = true) async {
        guard !screenshotMode, !refreshingModels else { return }
        refreshingModels = true
        defer { refreshingModels = false }
        var found = discovered
        var changed: [String] = []
        for provider in ProviderCatalog.default.providers {
            guard discovery.discoveryURL(for: provider) != nil else { continue }
            do {
                guard let result = try await discovery.discover(
                    provider: provider, secret: keyStore.secret(for: provider.id)) else { continue }
                let before = ModelDiscovery.resolvedModels(for: provider, discovered: found[provider.id])
                let after = ModelDiscovery.resolvedModels(for: provider, discovered: result)
                found[provider.id] = result
                if before != after { changed.append(provider.displayName) }
            } catch {
                continue   // a provider that cannot answer keeps its declared list
            }
        }
        let activeChanged = changed.contains { name in
            catalog.providers.first { $0.displayName == name }?.id == snapshot.activeProviderID
        }
        applyDiscovered(found)
        try? discoveredStore.save(found)
        if !changed.isEmpty {
            log(L("Modèles rafraîchis : %@.", changed.joined(separator: ", ")))
            // Adapters advertise the list, so they restart with the new pairing.
            ensureProxiesRunning()
            // Only the active provider's catalog is on disk; leave config.toml
            // alone otherwise, every write makes Codex reconnect.
            if activeChanged { installProviders() }
        } else if announce {
            log(L("Modèles à jour : aucun changement côté providers."))
        }
    }

    private func applyDiscovered(_ entries: [String: DiscoveredModels]) {
        discovered = entries
        catalog = ProviderCatalog(providers: ProviderCatalog.default.providers.map { provider in
            provider.withModels(ModelDiscovery.resolvedModels(
                for: provider, discovered: entries[provider.id]))
        })
        // Drop selections pointing at models the provider no longer serves.
        // The default model is re-added by `exposedModels` when missing.
        var pruned = modelSelection
        for provider in catalog.providers {
            if var selected = pruned[provider.id] {
                selected = selected.filter { provider.models.contains($0) }
                pruned[provider.id] = selected.isEmpty ? nil : selected
            }
        }
        modelSelection = pruned
        try? selectionStore.save(modelSelection)
    }

    /// When the models were last read from the providers.
    var lastModelRefresh: Date? {
        discovered.values.map(\.fetchedAt).max()
    }

    /// Looks for the OpenCode CLI. Runs `opencode --version`, so it stays off
    /// the main actor.
    func detectOpenCode() async {
        guard !screenshotMode else { return }
        openCode = await Task.detached(priority: .utility) { OpenCodeCLI.detect() }.value
        guard let install = openCode else {
            log(L("OpenCode CLI absent : la passerelle Zen publique reste utilisable."))
            return
        }
        let credential = install.hasZenCredential ? L("clé Zen OpenCode") : L("palier gratuit (clé publique)")
        log(L("OpenCode CLI %@ détecté (%@) · %@.", install.version ?? "?", install.executable.path, credential))
    }

    /// Seeds the key store from OpenCode's own credentials (`auth.json`). The
    /// user already granted these keys to the CLI; asking again in the panel is
    /// the duplication this app exists to remove. Only providers that still
    /// have no key are touched.
    func importKeysFromOpenCode() {
        guard !screenshotMode else { return }
        var imported: [String] = []
        for provider in catalog.providers where provider.requiresKey && !keyStore.hasKey(provider.id) {
            guard let key = OpenCodeCLI.storedKey(for: provider.id), !key.isEmpty else { continue }
            keyStore.setKey(key, for: provider.id)
            imported.append(provider.displayName)
        }
        if !imported.isEmpty {
            log(L("Clé(s) importée(s) depuis OpenCode : %@.", imported.joined(separator: ", ")))
        }
    }

    private func observeRouter() async {
        guard let router else { return }
        for await snap in router.changes {
            self.snapshot = snap
        }
    }

    private func computeInstalled() -> Bool {
        guard let cfg = try? configStore.readConfig() else { return false }
        return catalog.providers.filter { !$0.isReserved }.allSatisfy { cfg.contains("[model_providers.\($0.id)]") }
    }

    // MARK: Derived

    var activeProvider: Provider? { catalog[id: snapshot.activeProviderID] }
    var activeModel: String { snapshot.activeModel }
    var isActiveNative: Bool { snapshot.activeProviderID == "openai" }
    var keyEditingProvider: Provider? {
        catalog[id: editingProviderID ?? snapshot.activeProviderID]
    }
    var isScreenshotMode: Bool { screenshotMode }
    var keyCount: Int {
        screenshotMode ? screenshotKeyIDs.count : keyStore.providerIDs.count
    }
    func hasKey(for providerID: String) -> Bool {
        screenshotMode ? screenshotKeyIDs.contains(providerID) : keyStore.hasKey(providerID)
    }
    /// Models offered for the active provider. While masquerading, only models
    /// that own a native slug are listed: Codex's slug list is finite, and a
    /// model without one would end up outside the catalog Codex reads.
    var selectableModels: [String] {
        guard let provider = activeProvider else { return [] }
        let effective = effectiveCatalog[id: provider.id] ?? provider
        return ModelMasquerade.exposableModels(
            for: effective,
            cacheURL: configStore.paths.modelsCacheJson
        )
    }

    /// Providers with models reduced to the user-chosen exposed subset. The
    /// full discovered lists stay in `catalog` so the picker keeps every
    /// choice; everything Codex sees (catalog, profiles, adapter pairing) uses
    /// these effective providers instead.
    private var effectiveCatalog: ProviderCatalog {
        ProviderCatalog(providers: catalog.providers.map { provider in
            provider.withModels(exposedModels(for: provider.id))
        })
    }

    /// Number of native slugs Codex currently exposes (one per listed model).
    var modelSlots: Int {
        ModelMasquerade.listedSlotCount(cacheURL: configStore.paths.modelsCacheJson)
    }

    /// Models actually exposed for a provider: the full list when it fits in
    /// the native slug slots, otherwise the user's chosen subset, with the
    /// default model always guaranteed a slot.
    func exposedModels(for providerID: String) -> [String] {
        guard let provider = catalog[id: providerID] else { return [] }
        var result = ModelMasquerade.resolvedSelection(
            for: provider,
            selection: modelSelection[providerID],
            cacheURL: configStore.paths.modelsCacheJson
        )
        // Defensive pin: the active model must keep a slot so the running
        // selection stays valid even if a stale selection file says otherwise.
        if providerID == snapshot.activeProviderID,
           !snapshot.activeModel.isEmpty,
           !result.contains(snapshot.activeModel) {
            if result.count < modelSlots {
                result.append(snapshot.activeModel)
            } else if !result.isEmpty {
                result[result.count - 1] = snapshot.activeModel
            }
        }
        return result
    }

    /// Full model list of the active provider, for the selection checkboxes.
    var allModelsForActive: [String] {
        activeProvider?.models ?? []
    }

    /// How many slots the active provider currently occupies.
    var exposedModelCount: Int {
        exposedModels(for: snapshot.activeProviderID).count
    }

    /// The slot checkboxes only matter when the provider serves more models
    /// than Codex can expose — otherwise every model already has a slot.
    var shouldShowModelPicker: Bool {
        guard let provider = activeProvider, ModelMasquerade.masquerades(provider) else { return false }
        return modelSlots > 0 && provider.models.count > modelSlots
    }

    func isModelSelected(_ model: String, for providerID: String? = nil) -> Bool {
        exposedModels(for: providerID ?? snapshot.activeProviderID).contains(model)
    }

    /// Which models must keep a slot no matter what the user toggles.
    func modelLocked(_ model: String, for providerID: String? = nil) -> Bool {
        let id = providerID ?? snapshot.activeProviderID
        guard let provider = catalog[id: id] else { return false }
        if model == provider.defaultModel { return true }
        return id == snapshot.activeProviderID && model == snapshot.activeModel
    }

    /// Slug Codex believes it is talking to, when the active provider is exposed
    /// under one of Codex's own models. `nil` when no masquerading happens.
    var exposedModel: String? {
        guard let provider = activeProvider, ModelMasquerade.masquerades(provider) else { return nil }
        let effective = effectiveCatalog[id: provider.id] ?? provider
        let slug = ModelMasquerade.slug(
            for: snapshot.activeModel,
            provider: effective,
            cacheURL: configStore.paths.modelsCacheJson
        )
        return slug == snapshot.activeModel ? nil : slug
    }
    var hasKeyForActive: Bool {
        guard let p = activeProvider else { return false }
        return p.isKeyless || p.id == "openai" || hasKey(for: p.id)
    }

    // MARK: Install (once, additive)

    func installProviders(activeProviderID: String? = nil) {
        guard !screenshotMode else { return }
        do {
            let selectedProviderID = activeProviderID ?? snapshot.activeProviderID
            let report = try configStore.install(
                providers: effectiveCatalog.providers,
                activeProviderID: selectedProviderID
            )
            providersInstalled = true
            catalogConflict = !report.catalogInstalled && selectedProviderID != "openai"
            log(catalogConflict
                ? L("Providers installés, mais le catalogue Codex existant est conservé : vérifiez model_catalog_json.")
                : L("Providers ajoutés (additif): %@. OpenAI inchangé.", report.providersAdded.joined(separator: ", ")))
        } catch {
            log(L("Install échouée: %@", error.localizedDescription))
        }
    }

    func uninstall() {
        guard !screenshotMode else { return }
        do {
            _ = try configStore.uninstall()
            providersInstalled = computeInstalled()
            log(L("Providers retirés. Codex/OpenAI revient à l'état natif."))
        } catch {
            log(L("Uninstall échouée: %@", error.localizedDescription))
        }
    }

    // MARK: Select

    /// One-click selection: writes the provider config AND relaunches
    /// ChatGPT/Codex so the new provider + injected keys apply immediately.
    /// OpenAI = revert override (native ChatGPT).
    func select(providerID: String) async {
        guard !screenshotMode, let router else { return }
        stopConfigWatcher()
        defer { startConfigWatcher() }
        dismissKeyEditor()
        // A pending key-injection auto-apply belongs to the exact card click
        // that requested it; any other selection cancels it.
        applySelectionAfterKeyInjection = false
        applySelectionTargetID = nil
        let provider = catalog[id: providerID]
        let model = provider?.defaultModel ?? snapshot.activeModel
        do {
            if providerID == "openai" {
                _ = try configStore.revertOverride(allowLegacyUnmarked: true)
                installProviders(activeProviderID: "openai")
                snapshot = try await router.setActive(providerID: "openai", model: model)
                log(L("OpenAI natif : override supprimé, relance de ChatGPT/Codex…"))
            } else {
                guard let provider else { return }
                let effective = effectiveCatalog[id: provider.id] ?? provider
                if provider.requiresKey && !hasKey(for: provider.id) {
                    let persisted = keyStore.persistedProviderIDs().contains(provider.id)
                    log(persisted
                        ? L("Clé %@ présente sur disque mais pas en mémoire : relancez l'app pour la recharger.", provider.displayName)
                        : L("Saisissez d'abord la clé pour %1$@%2$@, puis cliquez sa carte à nouveau.", provider.displayName, persistenceEnabled ? "" : L(" (persistance locale désactivée)")))
                    applySelectionAfterKeyInjection = true
                    applySelectionTargetID = provider.id
                    presentKeySheet(for: provider.id)
                    return
                }
                // Write the new model/provider first. The config watcher can
                // then never observe a Claude catalog paired with the previous
                // GPT model and revert the selection to OpenAI.
                _ = try configStore.applyOverride(provider: effective, model: model)
                installProviders(activeProviderID: providerID)
                snapshot = try await router.setActive(providerID: providerID, model: model)
                log(L("Sélection : %@ · %@. Relance de ChatGPT/Codex…", provider.displayName, model))
            }
            await runTest()
            await refreshUsage(for: providerID, force: false)
            refreshRunningApps()
            await relaunchChatGPT()
        } catch {
            log(L("Select échouée: %@", error.localizedDescription))
        }
    }

    // MARK: Keys

    /// Switches the active model: writes the config override and relaunches
    /// ChatGPT/Codex so the new model applies in the Desktop.
    func setModel(_ model: String) async {
        guard !screenshotMode, let router, let provider = activeProvider else { return }
        stopConfigWatcher()
        defer { startConfigWatcher() }
        do {
            snapshot = try await router.setActive(providerID: provider.id, model: model)
            if provider.id != "openai" {
                let effective = effectiveCatalog[id: provider.id] ?? provider
                // Keep model_provider and model in sync before refreshing the
                // provider catalog, avoiding a transient old-provider state.
                _ = try configStore.applyOverride(provider: effective, model: model)
                installProviders(activeProviderID: provider.id)
                log(L("Modèle : %@. Relance de ChatGPT/Codex…", model))
                await relaunchChatGPT()
            } else {
                log(L("Modèle : %@.", model))
            }
        } catch {
            log(L("Changement de modèle échoué: %@", error.localizedDescription))
        }
    }

    /// Toggles a model in/out of the finite Codex slots for a provider. The
    /// default model and the active model are pinned; the change persists and
    /// re-applies immediately (catalog + adapter pairing + Desktop picker).
    func setModelSelected(_ model: String, selected: Bool, for providerID: String? = nil) async {
        guard !screenshotMode else { return }
        let targetID = providerID ?? snapshot.activeProviderID
        guard let provider = catalog[id: targetID] else { return }
        var current = exposedModels(for: targetID)
        var next: [String]
        if selected {
            guard !current.contains(model) else { return }
            if current.count < modelSlots {
                next = orderedExposed(current + [model], provider: provider)
            } else {
                // Selecting directly while full swaps the last optional model.
                // This keeps the finite Codex slot count without forcing users
                // to uncheck another model first.
                var protected = [provider.defaultModel]
                if targetID == snapshot.activeProviderID {
                    protected.append(snapshot.activeModel)
                }
                guard let replacementIndex = current.lastIndex(where: { !protected.contains($0) }) else {
                    return
                }
                current[replacementIndex] = model
                next = orderedExposed(current, provider: provider)
            }
        } else {
            guard !modelLocked(model, for: targetID) else { return }
            next = current.filter { $0 != model }
        }
        guard next != current else { return }
        modelSelection[targetID] = next
        try? selectionStore.save(modelSelection)

        stopConfigWatcher()
        defer { startConfigWatcher() }
        // The adapter advertises the new pairing; the active provider's static
        // catalog is regenerated so the Desktop picker only lists the choice.
        ensureProxiesRunning()
        if targetID == snapshot.activeProviderID {
            installProviders(activeProviderID: targetID)
            log(L("Modèles exposés (%1$lld/%2$lld) : %3$@. Relance de ChatGPT/Codex…", next.count, modelSlots, next.joined(separator: ", ")))
            await relaunchChatGPT()
        } else {
            log(L("Modèles exposés pour %@ : %@.", provider.displayName, next.joined(separator: ", ")))
        }
    }

    /// Orders an exposed subset with the default model first, the rest in the
    /// provider's own order.
    private func orderedExposed(_ models: [String], provider: Provider) -> [String] {
        let wanted = Set(models)
        var result: [String] = []
        var seen: Set<String> = []
        for model in [provider.defaultModel] + provider.models where wanted.contains(model) {
            if seen.insert(model).inserted { result.append(model) }
        }
        return result
    }

    func setSessionKey(_ value: String, for providerID: String? = nil) async {
        guard !screenshotMode else { return }
        let targetID = providerID ?? editingProviderID ?? snapshot.activeProviderID
        guard let provider = catalog[id: targetID] else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.id == "glm" {
            if trimmed.hasPrefix("sk-") {
                log(L("Attention : cette clé commence par « sk- » (format DeepSeek/OpenRouter). Une clé Z.ai se présente comme ID.secret — elle sera quand même testée."))
            } else if !trimmed.contains(".") {
                log(L("Attention : une clé Z.ai se présente comme ID.secret (ex. 6e6c…54d8.xxxx). La clé collée n'a pas ce format — elle sera quand même testée."))
            }
        }
        // A common failure mode is pasting an OpenRouter key while another card
        // owns the shared key field. Refuse it instead of silently creating an
        // unusable credential under DeepSeek or GLM.
        if trimmed.hasPrefix("sk-or-v1-"), provider.id != "openrouter" {
            log(L("Clé OpenRouter détectée dans le champ %@. Ouvrez la clé de la carte OpenRouter.", provider.displayName))
            editingProviderID = "openrouter"
            editingKey = true
            return
        }
        keyStore.setKey(value, for: provider.id)
        guard keyStore.hasKey(provider.id) else {
            log(L("Échec : clé non enregistrée pour %@.", provider.displayName))
            return
        }
        // A credential change must restart the managed proxy synchronously;
        // otherwise the running adapter would keep serving the previous key.
        log(keyStore.lastPersistenceError == nil
            ? L("Clé enregistrée pour %@. Activation…", provider.displayName)
            : L("Clé en mémoire pour %@, mais écriture disque impossible : %@", provider.displayName, keyStore.lastPersistenceError!))
        Task { await refreshUsage(for: provider.id, force: true) }
        ensureProxiesRunning()
        applySelectionAfterKeyInjection = false
        applySelectionTargetID = nil
        await select(providerID: provider.id)
        guard snapshot.activeProviderID == provider.id else { return }
        log(L("Clé %@ active · dernière tentative : consultez l’état du fournisseur.", provider.displayName))
    }

    func clearKey(for providerID: String? = nil) {
        guard !screenshotMode else { return }
        let targetID = providerID ?? editingProviderID ?? snapshot.activeProviderID
        guard let provider = catalog[id: targetID] else { return }
        keyStore.clear(providerID: provider.id)
        log(L("Clé effacée pour %@.", provider.displayName))
    }

    /// Shows the key editor for a specific provider. Presented inline in the
    /// panel (a `.sheet` from a MenuBarExtra window closes the window on macOS 26).
    func presentKeySheet(for providerID: String? = nil) {
        editingProviderID = providerID ?? snapshot.activeProviderID
        editingKey = true
    }

    func dismissKeyEditor() {
        editingKey = false
        editingProviderID = nil
    }

    // MARK: Compatibility test

    func runTest(providerID: String? = nil) async {
        guard !screenshotMode, let router, let provider = catalog[id: providerID ?? snapshot.activeProviderID] else { return }
        if provider.id == "openai" {
            // OpenAI auth is handled by Codex natively; nothing to test from here.
            await router.setCompatibility(for: provider.id, state: .compatible, error: nil)
            return
        }
        testing = true
        defer { testing = false }
        do {
            let result = try await checker.check(provider: provider, secret: keyStore.secret(for: provider.id))
            await router.setCompatibility(for: provider.id, state: result.state, error: result.errorDescription)
            log(result.errorDescription ?? "\(provider.displayName) /v1/responses OK.")
        } catch {
            let description = L(error.localizedDescription)
            await router.setCompatibility(
                for: provider.id,
                state: .incompatible(reason: description),
                error: description
            )
            log(description)
        }
    }

    /// Tests every non-native provider and records its own status, so the panel
    /// shows a per-provider health overview (not just the active one's).
    func runAllTests() async {
        guard !screenshotMode, let router else { return }
        testing = true
        defer { testing = false }
        let testable = catalog.providers.filter { $0.id != "openai" }
        var ok = 0
        for provider in testable {
            let secret = keyStore.secret(for: provider.id)
            if provider.requiresKey && secret == nil {
                await router.setCompatibility(
                    for: provider.id,
                    state: .incompatible(reason: L("Clé manquante")),
                    error: L("Saisissez la clé pour %@.", provider.displayName)
                )
                continue
            }
            do {
                let result = try await checker.check(provider: provider, secret: secret)
                if result.state == .compatible { ok += 1 }
                await router.setCompatibility(for: provider.id, state: result.state, error: result.errorDescription)
            } catch {
                let description = L(error.localizedDescription)
                await router.setCompatibility(
                    for: provider.id,
                    state: .incompatible(reason: description),
                    error: description
                )
            }
        }
        log(L("Test de tous les providers : %1$lld/%2$lld connectés.", ok, testable.count))
    }

    // MARK: Launch Codex CLI (native: --profile + env-key; OpenAI = bare)

    /// Launches Codex CLI in Terminal.app with the injected key. The key is
    /// staged in a 0600 temp env file sourced then immediately deleted — it
    /// never appears in the process arguments or ps output. OpenAI = bare codex.
    func launchCodexCLI() {
        guard !screenshotMode, let provider = activeProvider else { return }
        let key = keyStore.secret(for: provider.id)
        if provider.requiresKey && provider.id != "openai" && key == nil {
            log(L("Saisir d'abord la clé pour %@.", provider.displayName))
            presentKeySheet()
            return
        }
        guard let binary = AppState.findCodexExecutable() else {
            log(L("codex introuvable — installez le CLI Codex (npm i -g @openai/codex)."))
            return
        }
        let profile = provider.id == "openai" ? nil : provider.id
        let model = snapshot.activeModel

        var args = ""
        if let profile { args = " --profile \(profile)" }
        // This is Codex's supported equivalent of "Approve for me": automatic
        // review still runs inside the workspace-write sandbox. It is not full
        // access, which intentionally removes sandbox and confirmation paths.
        args += " --approve-for-me"
        // The key stays in the adapter: it is never written to a temp file, to
        // the process environment, or to the command line.
        let cmd = "\"\(binary.path)\"\(args)"

        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil {
            log(L("Codex CLI lancé dans Terminal (%1$@ · %2$@%3$@).", provider.displayName, model, profile.map { L(", profil %@", $0) } ?? L(", natif OpenAI")))
        } else {
            log(L("Lancement refusé (permission Automatisation). Autorisez AI Provider Switcher à contrôler Terminal."))
        }
    }

    // MARK: Persistence (optional local key file)

    func enablePersistence() {
        guard !screenshotMode else { return }
        do {
            _ = try keyStore.enablePersistence(at: KeyStore.defaultPersistentURL())
            persistenceEnabled = true
            log(L("Persistance locale activée (0600, hors iCloud). Moins sûr que le Trousseau."))
        } catch {
            log(L("Persistence: %@", error.localizedDescription))
        }
    }

    func disablePersistence() {
        guard !screenshotMode else { return }
        keyStore.disablePersistence()
        persistenceEnabled = false
    }

    // MARK: Running apps & relaunch

    func refreshRunningApps() {
        let running = NSWorkspace.shared.runningApplications
        chatGPTRunning = running.contains { app in
            let id = app.bundleIdentifier ?? ""
            return id == "com.openai.codex" || id.hasPrefix("com.openai.chat")
                || app.localizedName?.contains("ChatGPT") == true
        }
    }

    /// Restarts ChatGPT (which hosts Codex Desktop). No secret is injected into
    /// the child process: every routed provider gets its credential from its
    /// local adapter, which the app keeps up to date with the key it holds.
    func relaunchChatGPT() async {
        guard !screenshotMode else { return }
        let ws = NSWorkspace.shared
        let managedHostIDs: Set<String> = [
            "com.openai.codex",
            "com.openai.chatgpt",
            "com.openai.chat"
        ]
        let isCodexHost: (NSRunningApplication) -> Bool = { app in
            managedHostIDs.contains(app.bundleIdentifier ?? "")
        }
        let runningHosts = ws.runningApplications.filter(isCodexHost)
        for app in runningHosts {
            app.terminate()
        }

        // Do not reopen an existing Codex/ChatGPT process: it may keep the old
        // GPT catalog in memory and simply bring the old window to the front.
        // Wait for every matching host to exit, then force-terminate only those
        // exact app instances if macOS did not honor graceful termination.
        for _ in 0..<20 {
            if !ws.runningApplications.contains(where: isCodexHost) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        for app in ws.runningApplications where isCodexHost(app) {
            app.forceTerminate()
        }
        for _ in 0..<10 {
            if !ws.runningApplications.contains(where: isCodexHost) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        let bundleIDs = ["com.openai.codex", "com.openai.chatgpt", "com.openai.chat"]
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        do {
            let url = bundleIDs.lazy.compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
                ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
            guard FileManager.default.fileExists(atPath: url.path) else {
                log(L("ChatGPT introuvable."))
                return
            }
            _ = try await ws.openApplication(at: url, configuration: config)
            log(L("ChatGPT/Codex relancé — clés servies par les adaptateurs locaux."))
        } catch {
            log(L("Relance échouée: %@", error.localizedDescription))
        }
        refreshRunningApps()
    }

    // MARK: Local adapter proxies

    /// Codex Desktop only lists a provider's models if its `/models` endpoint
    /// answers in Codex's own schema; OpenAI-compatible providers don't. Each
    /// third-party provider is routed through a tiny local proxy that translates
    /// `/v1/models` and relays everything else (see Resources/provider-proxy.py).
    private var proxyProcesses: [Int32] = []

    /// Wire dialect the adapter must speak for this provider.
    static func adapterMode(for provider: Provider) -> String {
        switch provider.id {
        case "claude": return "anthropic"     // Responses <-> Anthropic Messages
        case "opencode": return "opencode"    // relay + OpenCode's own credentials
        case "opencode-go": return "opencode-go" // paid Go key + session affinity
        default: return "relay"
        }
    }

    /// Slug ↔ model pairing for a provider: Codex only ever sees the slug, so
    /// its native feature contract applies (see `ModelMasquerade`). Providers
    /// without an adapter keep their real model names.
    private func modelAliases(for provider: Provider) -> [ModelAlias] {
        guard ModelMasquerade.masquerades(provider) else {
            return provider.models.map { ModelAlias(slug: $0, model: $0, listed: true) }
        }
        return ModelMasquerade.aliases(for: provider, cacheURL: configStore.paths.modelsCacheJson)
    }

    /// Restarts a running proxy when the pairing changes — e.g. Codex refreshed
    /// `models_cache.json` and now exposes different native slugs.
    private func modelSignature(for provider: Provider) -> String {
        modelAliases(for: provider).map { "\($0.slug)=\($0.model)" }.joined(separator: ",")
    }

    // Bumped whenever the adapter contract changes (base URLs, pairing, flags):
    // a stale running proxy would otherwise be kept because its metadata still
    // matches everything this version compares.
    // v10: the adapter now normalizes Codex-only *input items* (`agent_message`,
    // an encrypted reasoning blob, `additional_tools`). A running v9 proxy would
    // keep rejecting every child thread with 422/400, so the version bump is
    // what makes the panel replace it instead of trusting the stale process.
    // v11: a namespaced `function_call` whose namespace is no longer in the
    // bridge (restarted proxy) used to be forwarded with its `namespace` key
    // intact; the wrapper is now always dropped before the provider sees it.
    private let proxyVersion = "2026-09-15-opencode-go-v12"

    /// Stable, non-reversible metadata used to detect credential changes and
    /// restart a proxy that still carries an older key.
    static func credentialFingerprint(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        return String(digest)
    }

    func ensureProxiesRunning() {
        for provider in effectiveCatalog.providers {
            guard let port = CodexConfigGenerator.proxyPort(for: provider.id) else { continue }
            let script = proxyScriptURL()
            if isPortOpen(port) {
                if restartStaleManagedProxyIfNeeded(
                    port: port,
                    provider: provider,
                    script: script
                ) {
                    usleep(150_000)
                } else {
                    let metadataURL = proxyMetadataURL(for: port)
                    if !FileManager.default.fileExists(atPath: metadataURL.path) {
                        log(L("Port proxy %1$lld déjà occupé pour %2$@ : processus externe conservé, redémarrage manuel nécessaire.", port, provider.displayName))
                    }
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: script.path) else {
                log(L("Proxy manquant pour %@: %@", provider.displayName, script.path))
                continue
            }
            let proc = Process()
            let aliases = modelAliases(for: provider)
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [
                script.path,
                String(port),
                provider.baseURL.absoluteString,
                provider.displayName,
                // Slugs Codex sees, then the provider models answering them.
                aliases.map(\.slug).joined(separator: ","),
                AppState.adapterMode(for: provider),
                provider.supportsTools ? "1" : "0",
                provider.supportsApplyPatch ? "1" : "0",
                provider.supportsImages ? "1" : "0",
                provider.supportsWebSearch ? "1" : "0",
                provider.supportsParallelToolCalls ? "1" : "0",
                provider.supportsCustomTools ? "1" : "0",
                aliases.map(\.model).joined(separator: ",")
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["AI_PROVIDER_SWITCHER_PROXY_VERSION"] = proxyVersion
            environment["AI_PROVIDER_SWITCHER_PROXY_STATE"] = proxyMetadataURL(for: port).path
            // Identity the proxy stamps on its Multi-Agent observations, so the
            // app keys them by provider + model instead of guessing from a name.
            environment["AI_PROVIDER_SWITCHER_PROVIDER_ID"] = provider.id
            environment["AI_PROVIDER_SWITCHER_STATE_DIR"] =
                KeyStore.defaultPersistentURL().deletingLastPathComponent().path
            if let key = keyStore.secret(for: provider.id)?.asString(), !key.isEmpty {
                environment["AI_PROVIDER_SWITCHER_PROXY_API_KEY"] = key
            }
            proc.environment = environment
            do {
                try proc.run()
                proxyProcesses.append(proc.processIdentifier)
                writeProxyMetadata(
                    port: port,
                    provider: provider,
                    pid: proc.processIdentifier
                )
                log(L("Proxy local %@ démarré (port %lld).", provider.displayName, port))
            } catch {
                log(L("Proxy %@ échoué: %@", provider.displayName, error.localizedDescription))
            }
        }
    }

    /// Copies the bundled adapter proxy to App Support (always refreshed so
    /// script updates propagate) and returns its path.
    private func proxyScriptURL() -> URL {
        let appSupport = KeyStore.defaultPersistentURL().deletingLastPathComponent()
        let dst = appSupport.appendingPathComponent("provider-proxy.py")
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("provider-proxy.py"),
            URL(fileURLWithPath: "/Users/lorrypoulier/Documents/GitHub/proxycodex/Resources/provider-proxy.py"),
            URL(fileURLWithPath: "Resources/provider-proxy.py")
        ]
        if let src = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let data = try? Data(contentsOf: src) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try? data.write(to: dst, options: [.atomic])
        }
        return dst
    }

    private func proxyMetadataURL(for port: Int) -> URL {
        KeyStore.defaultPersistentURL()
            .deletingLastPathComponent()
            .appendingPathComponent("proxy-\(port).json")
    }

    private func writeProxyMetadata(port: Int, provider: Provider, pid: Int32) {
        let values: [String: Any] = [
            "version": proxyVersion,
            "port": port,
            "provider": provider.id,
            "key_fingerprint": Self.credentialFingerprint(
                keyStore.secret(for: provider.id)?.asString()),
            "pid": pid,
            "supports_tools": provider.supportsTools,
            "supports_apply_patch": provider.supportsApplyPatch,
            "supports_images": provider.supportsImages,
            "supports_web_search": provider.supportsWebSearch,
            "supports_parallel_tools": provider.supportsParallelToolCalls,
            "supports_custom_tools": provider.supportsCustomTools,
            "models": modelSignature(for: provider)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]) else { return }
        let url = proxyMetadataURL(for: port)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func restartStaleManagedProxyIfNeeded(port: Int, provider: Provider, script: URL) -> Bool {
        let url = proxyMetadataURL(for: port)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNumber = metadata["pid"] as? NSNumber,
              let version = metadata["version"] as? String else {
            // Metadata can be lost when App Support is cleaned while the proxy
            // keeps running. Identify only our exact script + port, never an
            // arbitrary process occupying the port, then restart it.
            guard let pid = managedProxyPID(port: port, script: script) else { return false }
            kill(pid, SIGTERM)
            return true
        }
        let expected: [String: Any] = [
            "version": proxyVersion,
            "provider": provider.id,
            "key_fingerprint": Self.credentialFingerprint(
                keyStore.secret(for: provider.id)?.asString()),
            "supports_tools": provider.supportsTools,
            "supports_apply_patch": provider.supportsApplyPatch,
            "supports_images": provider.supportsImages,
            "supports_web_search": provider.supportsWebSearch,
            "supports_parallel_tools": provider.supportsParallelToolCalls,
            "supports_custom_tools": provider.supportsCustomTools,
            "models": modelSignature(for: provider)
        ]
        let stale = version != expected["version"] as? String
            || (metadata["key_fingerprint"] as? String) != expected["key_fingerprint"] as? String
            || (metadata["models"] as? String) != expected["models"] as? String
            || (metadata["provider"] as? String) != expected["provider"] as? String
            || (metadata["supports_tools"] as? Bool) != expected["supports_tools"] as? Bool
            || (metadata["supports_apply_patch"] as? Bool) != expected["supports_apply_patch"] as? Bool
            || (metadata["supports_images"] as? Bool) != expected["supports_images"] as? Bool
            || (metadata["supports_web_search"] as? Bool) != expected["supports_web_search"] as? Bool
            || (metadata["supports_parallel_tools"] as? Bool) != expected["supports_parallel_tools"] as? Bool
            || (metadata["supports_custom_tools"] as? Bool) != expected["supports_custom_tools"] as? Bool
        guard stale else { return false }

        let pid = pidNumber.int32Value
        let command = Process()
        let output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-p", String(pid), "-o", "command="]
        command.standardOutput = output
        do {
            try command.run()
            command.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard command.terminationStatus == 0,
                  text.contains(script.path),
                  text.contains(" \(port) ") else { return false }
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func managedProxyPID(port: Int, script: URL) -> Int32? {
        let command = Process()
        let output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-axo", "pid=,command="]
        command.standardOutput = output
        do {
            try command.run()
            command.waitUntilExit()
            guard command.terminationStatus == 0 else { return nil }
            let listing = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let portToken = String(port)
            for line in listing.split(separator: "\\n") {
                let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard fields.count == 2,
                      fields[1].contains(script.path),
                      fields[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(Substring(portToken)),
                      let pid = Int32(fields[0]) else { continue }
                return pid
            }
        } catch {
            return nil
        }
        return nil
    }

    private func isPortOpen(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        return result == 0
    }

    // MARK: Config watch (keep model_provider in sync with the Desktop picker)

    /// Codex routes a model through the provider named by the top-level
    /// `model_provider`; the Desktop picker only writes `model`, so third-party
    /// models would fall back to the ChatGPT backend (400 "not supported").
    /// Watch config.toml and repair `model_provider` when needed.
    private func startConfigWatcher() {
        guard !screenshotMode, configWatcher == nil else { return }
        let fd = open(configStore.paths.configToml.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.stopConfigWatcher()
                self.startConfigWatcher()
                return
            }
            self.scheduleConfigFix()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func stopConfigWatcher() {
        configWatcher?.cancel()
        configWatcher = nil
    }

    private func scheduleConfigFix() {
        guard configFixTask == nil else { return }
        configFixTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await self.fixModelProviderFromConfig()
            self.configFixTask = nil
        }
    }

    /// Keeps `config.toml`, the sidecar and the panel consistent after Codex has
    /// written to the file itself.
    ///
    /// The Desktop picker only writes `model`. Since a routed provider is exposed
    /// under Codex's own slugs, that value cannot identify the provider anymore —
    /// `model_provider` and the sidecar are the source of truth, and the slug is
    /// resolved back to the real provider model.
    func fixModelProviderFromConfig() async {
        guard !screenshotMode, let router,
              let model = configStore.topLevelValue(of: "model"),
              !model.isEmpty else { return }
        // The same write may have changed the Multi-Agent block (the user edits
        // config.toml by hand): re-read it so the panel reflects the file.
        refreshMultiAgentConfig()
        let configProvider = configStore.topLevelValue(of: "model_provider")
        let state = configStore.overrideState()

        // Codex (or the user) put the native provider back while an override was
        // still recorded: honor the file and return to native.
        if configProvider == "openai" || configProvider == nil {
            guard state != nil else { return }
            do {
                _ = try configStore.revertOverride()
                snapshot = try await router.setActive(
                    providerID: "openai",
                    model: catalog[id: "openai"]?.defaultModel ?? model
                )
                log(L("Retour au natif détecté dans config.toml : %@.", model))
            } catch {
                log(L("Revert config échoué: %@", error.localizedDescription))
            }
            return
        }

        guard let providerID = configProvider,
              let provider = catalog[id: providerID],
              provider.id != "openai" else { return }
        let effective = effectiveCatalog[id: providerID] ?? provider
        let resolved = ModelMasquerade.model(
            for: model,
            provider: effective,
            cacheURL: configStore.paths.modelsCacheJson
        )
        do {
            if state?.provider != provider.id || state?.model != resolved || state?.exposedModel != model {
                if !providersInstalled { installProviders(activeProviderID: provider.id) }
                // Codex writes config.toml itself when the user changes model or
                // effort in the Desktop. If the file already says what we would
                // write, only the sidecar has to catch up: rewriting it would
                // make Codex reload and drop its connection for nothing.
                if configStore.selectionMatchesConfig(provider: effective, exposedModel: model) {
                    _ = try configStore.recordSelection(
                        provider: effective, model: resolved, exposedModel: model)
                } else {
                    _ = try configStore.applyOverride(provider: effective, model: resolved)
                }
            }
            if snapshot.activeProviderID != provider.id || snapshot.activeModel != resolved {
                snapshot = try await router.setActive(providerID: provider.id, model: resolved)
                log(L("Sélection synchronisée depuis Codex : %@ · %@.", provider.displayName, resolved))
            }
        } catch {
            log(L("Sync config échouée: %@", error.localizedDescription))
        }
    }

    // MARK: Helpers

    static func findCodexExecutable() -> URL? {
        let candidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/usr/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
