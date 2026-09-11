import Foundation

/// Provider-neutral quota snapshot. Missing upstream data stays `nil`: the UI
/// must be able to distinguish “not exposed” from “zero”.
public struct ProviderUsageSnapshot: Sendable, Equatable {
    public let providerID: String
    public let fetchedAt: Date
    public let status: ProviderUsageStatus
    public let planLabel: String?
    public let balance: UsageBalance?
    public let windows: [UsageWindow]
    public let note: String?

    public init(
        providerID: String,
        fetchedAt: Date = Date(),
        status: ProviderUsageStatus,
        planLabel: String? = nil,
        balance: UsageBalance? = nil,
        windows: [UsageWindow] = [],
        note: String? = nil
    ) {
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        self.status = status
        self.planLabel = planLabel
        self.balance = balance
        self.windows = windows
        self.note = note
    }

    public var hasUsefulData: Bool {
        balance != nil || !windows.isEmpty
    }
}

public enum ProviderUsageStatus: Sendable, Equatable {
    case available
    case unsupported
    case unavailable
    case authenticationRequired
    case failed(String)
}

public struct UsageBalance: Sendable, Equatable {
    public let available: Decimal?
    public let total: Decimal?
    public let granted: Decimal?
    public let toppedUp: Decimal?
    public let used: Decimal?
    public let currency: String
    public let label: String

    public init(
        available: Decimal? = nil,
        total: Decimal? = nil,
        granted: Decimal? = nil,
        toppedUp: Decimal? = nil,
        used: Decimal? = nil,
        currency: String,
        label: String
    ) {
        self.available = available
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
        self.used = used
        self.currency = currency
        self.label = label
    }
}

public struct UsageWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public let detail: String?

    public init(
        id: String,
        label: String,
        usedPercent: Double?,
        durationMinutes: Int? = nil,
        resetsAt: Date? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
        self.detail = detail
    }

    public var remainingPercent: Double? {
        usedPercent.map { value in
            min(100, max(0, 100 - value))
        }
    }
}

public enum ProviderUsageError: Error, LocalizedError, Equatable {
    case http(Int)
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .invalidResponse: return "Réponse illisible"
        case .timeout: return "Délai dépassé"
        }
    }
}
