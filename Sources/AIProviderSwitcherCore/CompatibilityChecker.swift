import Foundation

public struct CompatibilityResult: Sendable, Equatable {
    public let state: CompatibilityState
    public let detail: String
    public init(state: CompatibilityState, detail: String = "") {
        self.state = state
        self.detail = detail
    }
    public var errorDescription: String? {
        switch state {
        case .untested: return nil
        case .compatible: return nil
        case .incompatible(let reason): return reason
        }
    }
}

/// Probes whether a provider actually serves `/v1/responses`. Used when a
/// provider is selected so the UI can warn if the Responses API is unsupported.
///
/// The probe never logs the key; the `Authorization` header is set in memory
/// only and the URL/status logged are non-sensitive.
public final class CompatibilityChecker: Sendable {
    public let client: HTTPClient
    public let timeout: TimeInterval
    public let localize: @Sendable (String) -> String

    public init(
        client: HTTPClient = URLSessionHTTPClient(),
        timeout: TimeInterval = 12,
        localize: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.client = client
        self.timeout = timeout
        self.localize = localize
    }

    public func check(provider: Provider, secret: Secret?) async throws -> CompatibilityResult {
        // A provider that needs a key cannot work without one: report it
        // directly instead of spending a round trip that returns a 401.
        if provider.requiresKey, secret?.asString()?.isEmpty != false {
            return CompatibilityResult(
                state: .incompatible(reason: localized("Clé manquante pour %@.", provider.displayName)),
                detail: "no key"
            )
        }
        // Routed providers are reached through the local adapter proxy: probe the
        // URL Codex actually uses (e.g. Anthropic has no /v1/responses upstream).
        let base: URL
        let throughProxy: Bool
        if let port = CodexConfigGenerator.proxyPort(for: provider.id) {
            base = URL(string: "http://127.0.0.1:\(port)/v1")!
            throughProxy = true
        } else {
            base = provider.baseURL
            throughProxy = false
        }
        let endpoint = base.appendingPathComponent("responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.requiresKey, let secret, let key = secret.asString(), !key.isEmpty {
            switch provider.authScheme {
            case .bearer: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .none: break
            }
        }
        // Minimal probe body. Providers that accept /v1/responses will respond
        // (2xx or a structured 4xx). A 404/405 indicates the endpoint is absent.
        // Do not let gateways choose their largest default completion budget:
        // OpenRouter can reject an authenticated probe with HTTP 402 before it
        // checks whether the endpoint works.
        let body: [String: Any] = [
            "model": provider.defaultModel,
            "input": "ping",
            "stream": false,
            "max_output_tokens": 1024
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await client.send(request)
        } catch {
            let reason = throughProxy
                ? localized(
                    "Adaptateur local arrêté pour %@ : lancez l'app puis réessayez.",
                    provider.displayName
                )
                : "Cannot reach \(provider.displayName): \(error.localizedDescription)"
            return CompatibilityResult(state: .incompatible(reason: reason), detail: error.localizedDescription)
        }
        let code = response.statusCode
        Log.info("Compatibility probe for \(provider.displayName) -> HTTP \(code) at \(endpoint.absoluteString)")
        // Some gateways (Z.ai notably) answer HTTP 200 with an error object in
        // the body for a rejected key, e.g. {"code":401,"msg":"token expired or
        // incorrect","success":false} or {"code":1000,"msg":"Authentication
        // Failed"}. A 2xx must not be treated as "connected" in that case.
        if let failure = Self.embeddedAuthFailure(data: data) {
            Log.info("Compatibility probe for \(provider.displayName) -> embedded auth failure (HTTP \(code))")
            return CompatibilityResult(
                state: .incompatible(reason: Self.userFacingFailure(
                    providerDisplayName: provider.displayName,
                    code: code,
                    failure: failure,
                    localize: localize
                )),
                detail: "HTTP \(code) auth"
            )
        }
        switch code {
        case 200...299:
            // Some gateways answer 2xx with an error payload (OpenCode Zen does
            // this for a restricted free tier). That is not "connected".
            if let payload = Self.embeddedErrorMessage(data: data) {
                return CompatibilityResult(
                    state: .incompatible(reason: "\(provider.displayName) : \(payload)"),
                    detail: "HTTP \(code) error payload"
                )
            }
            return CompatibilityResult(state: .compatible, detail: "HTTP \(code)")
        case 401, 403:
            let detail = Self.embeddedErrorMessage(data: data) ?? "HTTP \(code)"
            return CompatibilityResult(
                state: .incompatible(
                    reason: localized("%@ a refusé la clé : %@", provider.displayName, detail)
                ),
                detail: "HTTP \(code)"
            )
        case 404, 405:
            return CompatibilityResult(
                state: .incompatible(reason: "\(provider.displayName) does not expose /v1/responses (HTTP \(code))"),
                detail: "HTTP \(code)"
            )
        default:
            if code >= 500 {
                let detail = Self.embeddedErrorMessage(data: data) ?? "HTTP \(code)"
                return CompatibilityResult(
                    state: .incompatible(
                        reason: localized("%@ : erreur serveur — %@", provider.displayName, detail)
                    ),
                    detail: "HTTP \(code)"
                )
            }
            // Other 4xx still means the endpoint exists and parsed the request.
            return CompatibilityResult(state: .compatible, detail: "HTTP \(code)")
        }
    }

    /// Message an error payload carries, whatever its shape. Used to surface a
    /// gateway's own wording instead of a bare HTTP code.
    static func embeddedErrorMessage(data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Only explicit error envelopes count. A flat `msg` can be a quota
        // notice on an otherwise successful probe, which must stay "compatible".
        let errorObject = object["error"] as? [String: Any]
        let message = (errorObject?["message"] as? String)
            ?? (object["message"] as? String)
        guard let message, !message.isEmpty else { return nil }
        return message
    }

    /// Detects an authentication failure hidden inside an otherwise successful
    /// HTTP response. Handles both Z.ai's flat `{"code":401,"msg":…}` shape and
    /// the OpenAI-compatible `{"error":{"code":"401","message":…}}` shape.
    static func embeddedAuthFailure(data: Data) -> (code: String?, message: String?)? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let errorObject = object["error"] as? [String: Any]
        let codeValue = object["code"] ?? errorObject?["code"]
        let message = (object["msg"] as? String)
            ?? (object["message"] as? String)
            ?? (errorObject?["message"] as? String)
            ?? (errorObject?["msg"] as? String)

        if let codeValue {
            let codeString = "\(codeValue)"
            if ["401", "402", "403"].contains(codeString) {
                return (codeString, message?.isEmpty == false ? message : "code \(codeString)")
            }
        }
        guard let message, !message.isEmpty else { return nil }
        let text = message.lowercased()
        if text.contains("authentication failed")
            || text.contains("token expired")
            || text.contains("invalid api key")
            || text.contains("invalid key")
            || text.contains("unauthorized")
            || text.contains("bad credentials") {
            return (nil, message)
        }
        return nil
    }

    static func userFacingFailure(
        providerDisplayName: String,
        code: Int,
        failure: (code: String?, message: String?),
        localize: @Sendable (String) -> String = { $0 }
    ) -> String {
        let detail = failure.message
            ?? String(format: localize("erreur %@"), failure.code ?? String(code))
        if failure.code == "402" || code == 402 {
            return String(
                format: localize("%@ a refusé la requête : crédit ou budget de sortie insuffisant — %@"),
                providerDisplayName,
                detail
            )
        }
        return String(
            format: localize("%@ a refusé la clé : %@"),
            providerDisplayName,
            detail
        )
    }

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localize(key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }
}
