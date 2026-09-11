import Darwin
import Foundation

/// Reads only documented, provider-owned quota endpoints. Responses are
/// normalized into `ProviderUsageSnapshot`; unknown fields never fail parsing.
public struct ProviderUsageService: Sendable {
    public let client: HTTPClient
    public let timeout: TimeInterval

    public init(client: HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 8) {
        self.client = client
        self.timeout = timeout
    }

    // MARK: Public API

    public func snapshot(
        for provider: Provider,
        secret: Secret?
    ) async throws -> ProviderUsageSnapshot {
        switch provider.id {
        case "deepseek":
            guard let secret, !(secret.asString() ?? "").isEmpty else {
                return ProviderUsageSnapshot(providerID: provider.id, status: .authenticationRequired)
            }
            return try await deepSeekSnapshot(secret: secret)
        case "openrouter":
            guard let secret, !(secret.asString() ?? "").isEmpty else {
                return ProviderUsageSnapshot(providerID: provider.id, status: .authenticationRequired)
            }
            return try await openRouterSnapshot(secret: secret)
        case "glm":
            guard let secret, !(secret.asString() ?? "").isEmpty else {
                return ProviderUsageSnapshot(providerID: provider.id, status: .authenticationRequired)
            }
            return try await glmSnapshot(secret: secret)
        case "claude":
            return ProviderUsageSnapshot(
                providerID: provider.id,
                status: .unsupported,
                note: "Quota abonnement non exposé par une API supportée. Consultez /usage dans Claude Code."
            )
        case "opencode":
            return ProviderUsageSnapshot(
                providerID: provider.id,
                status: .unsupported,
                note: "Quota détaillé non exposé."
            )
        case "opencode-go":
            guard let secret, !(secret.asString() ?? "").isEmpty else {
                return ProviderUsageSnapshot(providerID: provider.id, status: .authenticationRequired)
            }
            return try await openCodeGoSnapshot(secret: secret)
        case "ollama":
            return ProviderUsageSnapshot(
                providerID: provider.id,
                status: .available,
                note: "Local · sans quota fournisseur."
            )
        default:
            return ProviderUsageSnapshot(providerID: provider.id, status: .unsupported)
        }
    }

    public func codexSnapshot(executable: URL) async throws -> ProviderUsageSnapshot {
        let payload = try await CodexAppServerClient.rateLimits(executable: executable, timeout: timeout)
        let object = (try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any]) ?? [:]
        return CodexUsageParser.snapshot(from: object, fetchedAt: Date())
    }

    // MARK: DeepSeek

    func deepSeekSnapshot(secret: Secret) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(secret.asString() ?? "")", forHTTPHeaderField: "Authorization")

        let (data, _) = try await validated(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }

        let infos = (object["balance_infos"] as? [[String: Any]]) ?? []
        let selected = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" }
            ?? infos.first
        let currency = (selected?["currency"] as? String ?? "USD").uppercased()
        let balance = UsageBalance(
            available: Self.decimal(selected?["total_balance"]),
            granted: Self.decimal(selected?["granted_balance"]),
            toppedUp: Self.decimal(selected?["topped_up_balance"]),
            currency: currency,
            label: "Crédit API"
        )
        let apiAvailable = object["is_available"] as? Bool ?? true
        return ProviderUsageSnapshot(
            providerID: "deepseek",
            fetchedAt: Date(),
            status: apiAvailable ? .available : .unavailable,
            balance: balance,
            note: apiAvailable ? nil : "Les appels API ne sont plus disponibles."
        )
    }

    // MARK: OpenRouter

    func openRouterSnapshot(secret: Secret) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(secret.asString() ?? "")", forHTTPHeaderField: "Authorization")

        let (data, _) = try await validated(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = root["data"] as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }

        let balance = UsageBalance(
            available: Self.decimal(key["limit_remaining"]),
            total: Self.decimal(key["limit"]),
            used: Self.decimal(key["usage"]),
            currency: "USD",
            label: "Budget de la clé"
        )
        var notes: [String] = []
        if let daily = Self.decimal(key["usage_daily"]) {
            notes.append("Aujourd'hui : \(Self.text(daily)) $")
        }
        if let weekly = Self.decimal(key["usage_weekly"]) {
            notes.append("7 jours : \(Self.text(weekly)) $")
        }
        if let monthly = Self.decimal(key["usage_monthly"]) {
            notes.append("Ce mois : \(Self.text(monthly)) $")
        }
        if let reset = key["limit_reset"] as? String, !reset.isEmpty {
            notes.append("Reset : \(reset)")
        }
        if key["is_free_tier"] as? Bool == true {
            notes.append("Palier gratuit")
        }
        return ProviderUsageSnapshot(
            providerID: "openrouter",
            fetchedAt: Date(),
            status: .available,
            balance: balance,
            note: notes.isEmpty ? nil : notes.joined(separator: " · ")
        )
    }

    // MARK: Z.ai coding plan

    func glmSnapshot(secret: Secret) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The official Z.ai plugin deliberately uses the raw token here; this
        // special case does not change normal Z.ai API authentication.
        request.setValue(secret.asString(), forHTTPHeaderField: "Authorization")

        let (data, _) = try await validated(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderUsageError.invalidResponse
        }
        return ZAIUsageParser.snapshot(from: object, providerID: "glm", fetchedAt: Date())
    }

    // MARK: OpenCode Go

    func openCodeGoSnapshot(secret: Secret) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(secret.asString() ?? "")", forHTTPHeaderField: "Authorization")

        let (data, _) = try await validated(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            throw ProviderUsageError.invalidResponse
        }
        return OpenCodeGoUsageParser.snapshot(from: usage, fetchedAt: Date())
    }

    // MARK: Helpers

    private func validated(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (response, data) = try await client.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw ProviderUsageError.http(response.statusCode)
            }
            return (data, response)
        } catch let error as ProviderUsageError {
            throw error
        } catch URLError.timedOut {
            throw ProviderUsageError.timeout
        }
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let decimal = value as? Decimal { return decimal }
        if let number = value as? NSNumber { return Decimal(number.doubleValue) }
        if let text = value as? String, let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) {
            return decimal
        }
        return nil
    }

    static func text(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

/// Tolerant parser for Z.ai. `TOKENS_LIMIT` is currently the coding-plan token
/// window; `TIME_LIMIT` is the MCP monthly limit. Future types are ignored.
public enum ZAIUsageParser {
    public static func snapshot(
        from root: Any,
        providerID: String,
        fetchedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for entry in quotaEntries(in: root) where !seen.contains(entry.type) {
            seen.insert(entry.type)
            if entry.type == "TOKENS_LIMIT" || entry.type.contains("TOKEN") {
                windows.append(entry.window)
            } else if let window = entry.windowWithKnownDuration {
                windows.append(window)
            }
        }
        return ProviderUsageSnapshot(
            providerID: providerID,
            fetchedAt: fetchedAt,
            status: windows.isEmpty ? .unavailable : .available,
            planLabel: "Coding Plan",
            windows: windows,
            note: windows.isEmpty ? "Quota non exposé par Z.ai." : nil
        )
    }

    private struct Entry {
        let type: String
        let percentage: Double?
        let label: String?
        let durationMinutes: Int?
        let resetDate: Date?

        var window: UsageWindow {
            UsageWindow(
                id: type,
                label: label ?? "Utilisation",
                usedPercent: percentage,
                durationMinutes: durationMinutes,
                resetsAt: resetDate,
                detail: resetDate == nil ? "Reset non exposé par Z.ai" : nil
            )
        }

        var windowWithKnownDuration: UsageWindow? {
            durationMinutes == nil ? nil : window
        }
    }

    private static func quotaEntries(in root: Any) -> [Entry] {
        var entries: [Entry] = []
        func walk(_ value: Any, inheritedType: String = "") {
            if let list = value as? [Any] {
                list.forEach { walk($0, inheritedType: inheritedType) }
            } else if let object = value as? [String: Any] {
                let typeCandidates = [object["type"], object["limitType"], object["limit_type"]]
                let explicitType = typeCandidates.compactMap { $0 as? String }.first ?? ""
                let type = explicitType.isEmpty && inheritedType.uppercased().contains("LIMIT")
                    ? inheritedType
                    : explicitType
                if type.uppercased().contains("LIMIT") {
                    entries.append(Entry(
                        type: type,
                        percentage: Self.percentage(object["percentage"] ?? object["usedPercent"]),
                        label: object["label"] as? String ?? object["title"] as? String,
                        durationMinutes: Self.integer(object["windowDurationMins"]
                            ?? object["window_duration_mins"]
                            ?? object["durationMinutes"]),
                        resetDate: Self.date(object["resetsAt"]
                            ?? object["reset_at"]
                            ?? object["resetTime"])
                    ))
                }
                object.forEach { key, value in
                    walk(value, inheritedType: explicitType.isEmpty ? key : explicitType)
                }
            }
        }
        walk(root)
        return entries
    }

    static func percentage(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000
                ? number.doubleValue / 1000 : number.doubleValue)
        }
        return nil
    }
}

/// Parses OpenCode Go's three subscription windows: rolling, weekly, monthly.
public enum OpenCodeGoUsageParser {
    public static func snapshot(
        from usage: [String: Any],
        fetchedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        let labels = [
            "rolling": "Glissant",
            "weekly": "7 jours",
            "monthly": "30 jours"
        ]
        let windows = ["rolling", "weekly", "monthly"].compactMap { key -> UsageWindow? in
            guard let entry = usage[key] as? [String: Any] else { return nil }
            return UsageWindow(
                id: key,
                label: labels[key] ?? key,
                usedPercent: Self.double(entry["percent"] ?? entry["usagePercent"]),
                resetsAt: Self.date(entry["resetsAt"] ?? entry["reset_at"]),
                detail: (entry["status"] as? String) == "rate-limited"
                    ? "Limite atteinte" : nil
            )
        }
        let rateLimited = windows.filter { $0.detail == "Limite atteinte" }
        return ProviderUsageSnapshot(
            providerID: "opencode-go",
            fetchedAt: fetchedAt,
            status: windows.isEmpty
                ? .unavailable
                : (rateLimited.count == windows.count ? .unavailable : .available),
            planLabel: "OpenCode Go",
            windows: windows,
            note: windows.isEmpty ? "Quota Go non exposé." : nil
        )
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Parser for the supported local Codex app-server rate-limit response.
/// Window identity always comes from its duration; primary/secondary names are
/// transport details and never imply fixed 5-hour or weekly meanings.
public enum CodexUsageParser {
    public static func snapshot(
        from response: [String: Any],
        fetchedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        let account = response["result"] as? [String: Any] ?? response
        let codexLimits = ((account["rateLimitsByLimitId"] as? [String: Any])?["codex"]) as? [String: Any]
        let selected = ((codexLimits?["rateLimits"] as? [String: Any])
            ?? (account["rateLimits"] as? [String: Any])
            ?? codexLimits)
        var windows = parseWindows(from: selected)

        if windows.isEmpty, let list = selected?["limits"] as? [[String: Any]] {
            windows = list.compactMap(parse(window:))
        }
        let credits = account["credits"] as? [String: Any] ?? selected?["credits"] as? [String: Any]
        let balance = credits.flatMap { credits in
            Self.decimal(credits["balance"]).map {
                UsageBalance(available: $0, currency: "USD", label: "Crédits")
            }
        }
        return ProviderUsageSnapshot(
            providerID: "openai",
            fetchedAt: fetchedAt,
            status: windows.isEmpty && balance == nil ? .unavailable : .available,
            balance: balance,
            windows: windows,
            note: windows.isEmpty && balance == nil ? "Quota non exposé par Codex." : nil
        )
    }

    static func parseWindows(from rateLimits: [String: Any]?) -> [UsageWindow] {
        guard let rateLimits else { return [] }
        let named = [
            ("primary", rateLimits["primary"] as? [String: Any]),
            ("secondary", rateLimits["secondary"] as? [String: Any])
        ].compactMap { $0.1.map { $0 } }
        let parsed = named.compactMap(parse(window:))
            .sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
        return parsed.isEmpty
            ? ((rateLimits["windows"] as? [[String: Any]]) ?? []).compactMap(parse(window:))
            : parsed
    }

    static func parse(window object: [String: Any]) -> UsageWindow? {
        guard let duration = Self.integer(object["windowDurationMins"]
            ?? object["window_duration_mins"]) else {
            return nil
        }
        let used = Self.percentage(object["usedPercent"] ?? object["used_percent"])
        let reset = Self.date(object["resetsAt"])
        return UsageWindow(
            id: "window-\(duration)",
            label: Self.label(forMinutes: duration),
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: reset
        )
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 60: return "1 heure"
        case 300: return "5 heures"
        case 1440: return "24 heures"
        case 10080: return "7 jours"
        case 43200: return "30 jours"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440) jours" }
            if minutes % 60 == 0 { return "\(minutes / 60) heures" }
            return "\(minutes) minutes"
        }
    }

    static func percentage(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return Decimal(number.doubleValue) }
        if let text = value as? String { return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }
}

/// Minimal newline-delimited JSON-RPC client for the local app-server process.
/// It never reads `auth.json` and only asks for the supported rate-limit route.
struct CodexAppServerPayload: Sendable {
    let data: Data
}

enum CodexAppServerClient {
    static func rateLimits(executable: URL, timeout: TimeInterval) async throws -> CodexAppServerPayload {
        try await Task.detached(priority: .userInitiated) {
            CodexAppServerPayload(data: try synchronousRateLimits(executable: executable, timeout: timeout))
        }.value
    }

    private static func synchronousRateLimits(executable: URL, timeout: TimeInterval) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = Pipe()
        // Capture this before launch: an immediately exiting child can make
        // Foundation invalidate its FileHandle wrapper while the quota task is
        // still setting up. The integer descriptor stays safe to probe.
        let stdinFD = stdout.fileHandleForWriting.fileDescriptor

        final class StreamState: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            private var ended = false
            let semaphore = DispatchSemaphore(value: 0)

            func append(_ data: Data) {
                lock.lock()
                if data.isEmpty {
                    if !ended {
                        ended = true
                        semaphore.signal()
                    }
                } else {
                    storage.append(data)
                }
                lock.unlock()
            }

            var data: Data {
                lock.withLock { storage }
            }
        }
        let state = StreamState()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                if !process.waitForExit(timeout: .now() + 1) {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
        }

        // Foundation's FileHandle raises Objective-C exceptions on EPIPE. A
        // short-lived app-server can legitimately close before our next RPC,
        // so raw POSIX writes keep that observable as a controlled error.
        signal(SIGPIPE, SIG_IGN)

        func send(_ object: [String: Any]) throws {
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try Self.write(data, to: stdinFD)
            }
        }

        func response(id: Int) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let messages = Self.messages(in: state.data)
                for message in messages {
                    if (message["id"] as? Int) == id {
                        return message
                    }
                }
                _ = state.semaphore.wait(timeout: .now() + 0.1)
            }
            throw ProviderUsageError.timeout
        }

        try send([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "proxycodex",
                    "title": "Proxycodex",
                    "version": "1.0"
                ]
            ]
        ])
        let initialize = try response(id: 1)
        if initialize["error"] != nil { throw ProviderUsageError.invalidResponse }
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 2, "params": [:]])
        let usage = try response(id: 2)
        return try JSONSerialization.data(withJSONObject: usage)
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let count = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if errno == EPIPE || errno == EBADF {
                throw ProviderUsageError.pipeClosed
            } else {
                throw ProviderUsageError.invalidResponse
            }
        }
    }

    static func messages(in data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
    }
}

extension Process {
    func waitForExit(timeout: DispatchTime) -> Bool {
        while isRunning && DispatchTime.now() < timeout {
            usleep(20_000)
        }
        return !isRunning
    }
}
