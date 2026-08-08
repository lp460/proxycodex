import Foundation
import SwiftUI
import AppKit
import Darwin
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

    let catalog = ProviderCatalog.default
    let keyStore = KeyStore()
    let checker = CompatibilityChecker()
    let configStore = CodexConfigStore()

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
    @Published private(set) var logs: [LogEntry] = []

    private var observationTask: Task<Void, Never>?
    private var nextLogID = 1
    private let maxLogs = 100
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configFixTask: Task<Void, Never>?

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
                    "claude": .compatible
                ]
            )
            router = try? ProviderRouter(
                catalog: catalog,
                keyResolver: keyStore,
                initialProviderID: "deepseek"
            )
            nativeConfigDetected = true
            providersInstalled = true
            statusMessage = "Démonstration prête · aucun secret réel utilisé."
        } else {
            // Keep keys across restarts: persistence is ON by default (0600 file,
            // excluded from iCloud). Keys are loaded back into memory at launch so
            // they never have to be re-entered; the footer toggle can disable it.
            _ = try? keyStore.enablePersistence(at: KeyStore.defaultPersistentURL())
            persistenceEnabled = keyStore.persistenceEnabled
            _ = try? keyStore.loadFromDisk()
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
                win.setContentSize(NSSize(width: 388, height: 680))
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
                ? "Codex natif détecté (\(configStore.paths.codexHome.path))."
                : "Aucun ~/.codex/config.toml ; lancez Codex une fois, puis « Installer les providers ».")
        } catch {
            log("Init error: \(error.localizedDescription)")
        }
        refreshRunningApps()
        log("Catalogue chargé : \(catalog.providers.map(\.displayName).joined(separator: ", ")).")
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
                providers: catalog.providers,
                activeProviderID: selectedProviderID
            )
            providersInstalled = true
            catalogConflict = !report.catalogInstalled && selectedProviderID != "openai"
            log(catalogConflict
                ? "Providers installés, mais le catalogue Codex existant est conservé : vérifiez model_catalog_json."
                : "Providers ajoutés (additif): \(report.providersAdded.joined(separator: ", ")). OpenAI inchangé.")
        } catch {
            log("Install échouée: \(error.localizedDescription)")
        }
    }

    func uninstall() {
        guard !screenshotMode else { return }
        do {
            _ = try configStore.uninstall()
            providersInstalled = computeInstalled()
            log("Providers retirés. Codex/OpenAI revient à l'état natif.")
        } catch {
            log("Uninstall échouée: \(error.localizedDescription)")
        }
    }

    // MARK: Select

    /// One-click selection: writes the provider config AND relaunches
    /// ChatGPT/Codex so the new provider + injected keys apply immediately.
    /// OpenAI = revert override (native ChatGPT).
    func select(providerID: String) async {
        guard !screenshotMode, let router else { return }
        dismissKeyEditor()
        let provider = catalog[id: providerID]
        let model = provider?.defaultModel ?? snapshot.activeModel
        do {
            if providerID == "openai" {
                _ = try configStore.revertOverride()
                installProviders(activeProviderID: "openai")
                _ = try await router.setActive(providerID: "openai", model: model)
                log("OpenAI natif : override supprimé, relance de ChatGPT/Codex…")
            } else {
                guard let provider else { return }
                if provider.requiresKey && !hasKey(for: provider.id) {
                    log("Saisissez d'abord la clé pour \(provider.displayName), puis cliquez sa carte à nouveau.")
                    presentKeySheet(for: provider.id)
                    return
                }
                installProviders(activeProviderID: providerID)
                _ = try configStore.applyOverride(provider: provider, model: model)
                _ = try await router.setActive(providerID: providerID, model: model)
                log("Sélection : \(provider.displayName) · \(model). Relance de ChatGPT/Codex…")
            }
            await runTest()
            refreshRunningApps()
            await relaunchChatGPT()
        } catch {
            log("Select échouée: \(error.localizedDescription)")
        }
    }

    // MARK: Keys

    /// Switches the active model: writes the config override and relaunches
    /// ChatGPT/Codex so the new model applies in the Desktop.
    func setModel(_ model: String) async {
        guard !screenshotMode, let router, let provider = activeProvider else { return }
        do {
            _ = try await router.setActive(providerID: provider.id, model: model)
            if provider.id != "openai" {
                installProviders(activeProviderID: provider.id)
                _ = try configStore.applyOverride(provider: provider, model: model)
                log("Modèle : \(model). Relance de ChatGPT/Codex…")
                await relaunchChatGPT()
            } else {
                log("Modèle : \(model).")
            }
        } catch {
            log("Changement de modèle échoué: \(error.localizedDescription)")
        }
    }

    func setSessionKey(_ value: String, for providerID: String? = nil) async {
        guard !screenshotMode else { return }
        let targetID = providerID ?? editingProviderID ?? snapshot.activeProviderID
        guard let provider = catalog[id: targetID] else { return }
        keyStore.setKey(value, for: provider.id)
        log("Clé injectée en mémoire pour \(provider.displayName).")
        await runTest(providerID: provider.id)
    }

    func clearKey(for providerID: String? = nil) {
        guard !screenshotMode else { return }
        let targetID = providerID ?? editingProviderID ?? snapshot.activeProviderID
        guard let provider = catalog[id: targetID] else { return }
        keyStore.clear(providerID: provider.id)
        log("Clé effacée pour \(provider.displayName).")
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
            await router.setCompatibility(for: provider.id, state: .incompatible(reason: error.localizedDescription), error: error.localizedDescription)
            log(error.localizedDescription)
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
                    state: .incompatible(reason: "Clé manquante"),
                    error: "Saisissez la clé pour \(provider.displayName)."
                )
                continue
            }
            do {
                let result = try await checker.check(provider: provider, secret: secret)
                if result.state == .compatible { ok += 1 }
                await router.setCompatibility(for: provider.id, state: result.state, error: result.errorDescription)
            } catch {
                await router.setCompatibility(
                    for: provider.id,
                    state: .incompatible(reason: error.localizedDescription),
                    error: error.localizedDescription
                )
            }
        }
        log("Test de tous les providers : \(ok)/\(testable.count) connectés.")
    }

    // MARK: Launch Codex CLI (native: --profile + env-key; OpenAI = bare)

    /// Launches Codex CLI in Terminal.app with the injected key. The key is
    /// staged in a 0600 temp env file sourced then immediately deleted — it
    /// never appears in the process arguments or ps output. OpenAI = bare codex.
    func launchCodexCLI() {
        guard !screenshotMode, let provider = activeProvider else { return }
        let key = keyStore.secret(for: provider.id)
        if provider.requiresKey && provider.id != "openai" && key == nil {
            log("Saisir d'abord la clé pour \(provider.displayName).")
            presentKeySheet()
            return
        }
        guard let binary = AppState.findCodexExecutable() else {
            log("codex introuvable — installez le CLI Codex (npm i -g @openai/codex).")
            return
        }
        let profile = provider.id == "openai" ? nil : provider.id
        let model = snapshot.activeModel

        var envSetup = ""
        if let key, let value = key.asString(), !value.isEmpty, !provider.environmentVariable.isEmpty {
            let envFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("aps-\(provider.id)-env.sh")
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            let content = "export \(provider.environmentVariable)='\(escaped)'\n"
            try? content.write(to: envFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: envFile.path)
            envSetup = "set -a; source \"\(envFile.path)\"; rm -f \"\(envFile.path)\"; set +a; "
        }

        var args = ""
        if let profile { args = " --profile \(profile)" }
        let cmd = envSetup + "\"\(binary.path)\"\(args)"

        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil {
            log("Codex CLI lancé dans Terminal (\(provider.displayName) · \(model)\(profile.map { ", profil \($0)" } ?? ", natif OpenAI")).")
        } else {
            log("Lancement refusé (permission Automatisation). Autorisez AI Provider Switcher à contrôler Terminal.")
        }
    }

    // MARK: Persistence (optional local key file)

    func enablePersistence() {
        guard !screenshotMode else { return }
        do {
            _ = try keyStore.enablePersistence(at: KeyStore.defaultPersistentURL())
            persistenceEnabled = true
            log("Persistance locale activée (0600, hors iCloud). Moins sûr que le Trousseau.")
        } catch {
            log("Persistence: \(error.localizedDescription)")
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

    /// Env vars for every provider key held in memory (used when relaunching
    /// ChatGPT/Codex so the Desktop picker can resolve env_key providers).
    private var keyEnv: [String: String] {
        var env: [String: String] = [:]
        for provider in catalog.providers where !provider.environmentVariable.isEmpty {
            if let secret = keyStore.secret(for: provider.id)?.asString() {
                env[provider.environmentVariable] = secret
            }
        }
        return env
    }

    /// Restarts ChatGPT (which hosts Codex Desktop). The embedded codex server
    /// reads `env_key` providers from ~/.codex/config.toml, so every key held in
    /// memory is injected into the relaunched process' environment — without
    /// them the desktop model picker can only offer ChatGPT/OpenAI.
    func relaunchChatGPT() async {
        guard !screenshotMode else { return }
        let bundleID = "com.openai.codex"
        let env = keyEnv
        let ws = NSWorkspace.shared
        for app in ws.runningApplications where app.bundleIdentifier == bundleID {
            app.terminate()
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        if !env.isEmpty {
            config.environment = env
        }
        do {
            let url = ws.urlForApplication(withBundleIdentifier: bundleID)
                ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
            guard FileManager.default.fileExists(atPath: url.path) else {
                log("ChatGPT introuvable.")
                return
            }
            _ = try await ws.openApplication(at: url, configuration: config)
            log(env.isEmpty
                ? "ChatGPT/Codex relancé — configuration native."
                : "ChatGPT/Codex relancé avec \(env.count) clé(s) injectée(s).")
        } catch {
            log("Relance échouée: \(error.localizedDescription)")
        }
        refreshRunningApps()
    }

    // MARK: Local adapter proxies

    /// Codex Desktop only lists a provider's models if its `/models` endpoint
    /// answers in Codex's own schema; OpenAI-compatible providers don't. Each
    /// third-party provider is routed through a tiny local proxy that translates
    /// `/v1/models` and relays everything else (see Resources/provider-proxy.py).
    private var proxyProcesses: [Int32] = []
    private let proxyVersion = "2026-08-08-tools-v2"

    func ensureProxiesRunning() {
        for provider in catalog.providers {
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
                        log("Port proxy \(port) déjà occupé pour \(provider.displayName) : processus externe conservé, redémarrage manuel nécessaire.")
                    }
                    continue
                }
            }
            guard FileManager.default.fileExists(atPath: script.path) else {
                log("Proxy manquant pour \(provider.displayName): \(script.path)")
                continue
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [
                script.path,
                String(port),
                provider.baseURL.absoluteString,
                provider.displayName,
                provider.models.joined(separator: ","),
                provider.id == "claude" ? "anthropic" : "relay",
                provider.supportsTools ? "1" : "0",
                provider.supportsImages ? "1" : "0",
                provider.supportsWebSearch ? "1" : "0",
                provider.supportsParallelToolCalls ? "1" : "0"
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["AI_PROVIDER_SWITCHER_PROXY_VERSION"] = proxyVersion
            environment["AI_PROVIDER_SWITCHER_PROXY_STATE"] = proxyMetadataURL(for: port).path
            proc.environment = environment
            do {
                try proc.run()
                proxyProcesses.append(proc.processIdentifier)
                writeProxyMetadata(
                    port: port,
                    provider: provider,
                    pid: proc.processIdentifier
                )
                log("Proxy local \(provider.displayName) démarré (port \(port)).")
            } catch {
                log("Proxy \(provider.displayName) échoué: \(error.localizedDescription)")
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
            "pid": pid,
            "supports_tools": provider.supportsTools,
            "supports_images": provider.supportsImages,
            "supports_web_search": provider.supportsWebSearch,
            "supports_parallel_tools": provider.supportsParallelToolCalls
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
            return false
        }
        let expected: [String: Any] = [
            "version": proxyVersion,
            "provider": provider.id,
            "supports_tools": provider.supportsTools,
            "supports_images": provider.supportsImages,
            "supports_web_search": provider.supportsWebSearch,
            "supports_parallel_tools": provider.supportsParallelToolCalls
        ]
        let stale = version != expected["version"] as? String
            || (metadata["provider"] as? String) != expected["provider"] as? String
            || (metadata["supports_tools"] as? Bool) != expected["supports_tools"] as? Bool
            || (metadata["supports_images"] as? Bool) != expected["supports_images"] as? Bool
            || (metadata["supports_web_search"] as? Bool) != expected["supports_web_search"] as? Bool
            || (metadata["supports_parallel_tools"] as? Bool) != expected["supports_parallel_tools"] as? Bool
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

    func fixModelProviderFromConfig() async {
        guard !screenshotMode,
              let model = configStore.topLevelValue(of: "model"),
              !model.isEmpty else { return }
        let provider = catalog.providers.first { !$0.isReserved && $0.models.contains(model) }
        let current = configStore.topLevelValue(of: "model_provider")
        if let provider {
            if current != provider.id {
                if !providersInstalled { installProviders(activeProviderID: provider.id) }
                do {
                    _ = try configStore.applyOverride(provider: provider, model: model)
                    log("Provider auto-synchronisé : \(provider.displayName) (modèle \(model)).")
                } catch {
                    log("Sync config échouée: \(error.localizedDescription)")
                }
            }
        } else if let current, current != "openai" {
            do {
                _ = try configStore.revertOverride()
                log("Retour au natif : \(model).")
            } catch {
                log("Revert config échoué: \(error.localizedDescription)")
            }
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
