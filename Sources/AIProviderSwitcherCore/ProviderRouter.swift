import Foundation

/// Resolves a `Secret` for a provider id. Implemented by `KeyStore`.
public protocol KeyResolver: Sendable {
    func secret(for providerID: String) -> Secret?
}

public enum CompatibilityState: Sendable, Equatable {
    case untested
    case compatible
    case incompatible(reason: String)
}

/// Immutable point-in-time view of the router, consumed by the UI.
public struct RouterSnapshot: Sendable, Equatable {
    public let activeProviderID: String
    public let activeModel: String
    /// Per-provider compatibility state, so the UI can show each provider's
    /// own connectivity status rather than only the active one's.
    public var compatibilities: [String: CompatibilityState]
    public var errors: [String: String]
    public init(
        activeProviderID: String,
        activeModel: String,
        compatibility: CompatibilityState = .untested,
        lastError: String? = nil,
        compatibilities: [String: CompatibilityState]? = nil,
        errors: [String: String]? = nil
    ) {
        self.activeProviderID = activeProviderID
        self.activeModel = activeModel
        self.compatibilities = compatibilities ?? [:]
        if self.compatibilities[activeProviderID] == nil {
            self.compatibilities[activeProviderID] = compatibility
        }
        self.errors = errors ?? [:]
        if let lastError, self.errors[activeProviderID] == nil {
            self.errors[activeProviderID] = lastError
        }
    }

    /// Compatibility state of the active provider.
    public var compatibility: CompatibilityState {
        get { compatibilities[activeProviderID] ?? .untested }
        set { compatibilities[activeProviderID] = newValue }
    }

    /// Last error of the active provider.
    public var lastError: String? {
        get { errors[activeProviderID] }
        set { errors[activeProviderID] = newValue }
    }

    /// Compatibility state for a given provider id.
    public func compatibility(for providerID: String) -> CompatibilityState {
        compatibilities[providerID] ?? .untested
    }
}

/// Provider + secret captured atomically at the start of a request, so that an
/// in-flight request is unaffected by a subsequent provider switch.
public struct ResolvedRoute: Sendable {
    public let provider: Provider
    public let secret: Secret? // nil for keyless providers
    public init(provider: Provider, secret: Secret?) {
        self.provider = provider
        self.secret = secret
    }
}

/// Errors thrown when changing the active provider.
public enum RouterError: Error, Equatable, LocalizedError {
    case unknownProvider(String)
    case missingKey(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id): return "Provider unknown: \(id)"
        case .missingKey(let id): return "No API key in memory for provider: \(id)"
        }
    }
}

/// Atomic holder of the active provider/model. The proxy resolves each request
/// through `resolve()` so a switch takes effect for the next request without a
/// restart, while an in-flight request keeps its captured route.
public actor ProviderRouter {
    private let catalog: ProviderCatalog
    private let keyResolver: KeyResolver
    private var snapshot: RouterSnapshot
    private let changesContinuation: AsyncStream<RouterSnapshot>.Continuation
    public nonisolated let changes: AsyncStream<RouterSnapshot>

    public init(catalog: ProviderCatalog, keyResolver: KeyResolver, initialProviderID: String) throws {
        guard catalog[id: initialProviderID] != nil else { throw RouterError.unknownProvider(initialProviderID) }
        self.catalog = catalog
        self.keyResolver = keyResolver
        let model = catalog[id: initialProviderID]?.defaultModel ?? ""
        self.snapshot = RouterSnapshot(activeProviderID: initialProviderID, activeModel: model)
        var continuation: AsyncStream<RouterSnapshot>.Continuation!
        self.changes = AsyncStream { continuation = $0 }
        self.changesContinuation = continuation
    }

    public func currentSnapshot() -> RouterSnapshot { snapshot }

    public func activeProvider() -> Provider? { catalog[id: snapshot.activeProviderID] }

    /// Instantly switches the active provider/model. Does NOT perform a network
    /// compatibility test. Used when the proxy must switch immediately.
    @discardableResult
    public func setActive(providerID: String, model: String? = nil) throws -> RouterSnapshot {
        guard let provider = catalog[id: providerID] else {
            throw RouterError.unknownProvider(providerID)
        }
        let resolvedModel = model ?? provider.defaultModel
        snapshot = RouterSnapshot(
            activeProviderID: providerID,
            activeModel: resolvedModel,
            lastError: nil,
            compatibilities: snapshot.compatibilities,
            errors: snapshot.errors
        )
        publish()
        return snapshot
    }

    /// Records a compatibility result for the current provider.
    public func setCompatibility(_ state: CompatibilityState, error: String? = nil) {
        setCompatibility(for: snapshot.activeProviderID, state: state, error: error)
    }

    /// Records a compatibility result for a specific provider.
    public func setCompatibility(for providerID: String, state: CompatibilityState, error: String? = nil) {
        snapshot.compatibilities[providerID] = state
        if let error {
            snapshot.errors[providerID] = error
        } else {
            snapshot.errors[providerID] = nil
        }
        publish()
    }

    /// Full selection: instant switch + optional compatibility test. The switch
    /// happens synchronously and is not reverted if the compatibility test fails
    /// (the proxy still uses the active provider), but the error is surfaced.
    public func select(
        providerID: String,
        model: String? = nil,
        compatibilityChecker: CompatibilityChecker? = nil
    ) async throws -> RouterSnapshot {
        let previousProviderID = snapshot.activeProviderID
        guard let provider = catalog[id: providerID] else {
            throw RouterError.unknownProvider(providerID)
        }
        if provider.requiresKey, keyResolver.secret(for: providerID) == nil {
            throw RouterError.missingKey(providerID)
        }
        _ = try setActive(providerID: providerID, model: model)
        Log.info("Active provider set to \(provider.displayName), model=\(model ?? provider.defaultModel)")
        if let checker = compatibilityChecker {
            // Don't fail the whole switch on a checker error for keyless providers.
            do {
                let result = try await checker.check(provider: provider, secret: keyResolver.secret(for: providerID))
                setCompatibility(result.state, error: result.errorDescription)
            } catch {
                // Keep the switch (proxy can still attempt), surface the error.
                setCompatibility(.incompatible(reason: error.localizedDescription), error: error.localizedDescription)
                Log.warning("Compatibility check failed for \(provider.displayName): \(error.localizedDescription)")
            }
        } else {
            setCompatibility(.untested)
        }
        _ = previousProviderID // kept for potential rollback policy
        return snapshot
    }

    /// Atomically resolves provider + secret for a single request.
    public func resolve() -> ResolvedRoute? {
        guard let provider = activeProvider() else { return nil }
        let secret = keyResolver.secret(for: provider.id)
        if provider.requiresKey, secret == nil { return nil }
        return ResolvedRoute(provider: provider, secret: secret)
    }

    private func publish() {
        changesContinuation.yield(snapshot)
    }
}
