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

    public init(client: HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 12) {
        self.client = client
        self.timeout = timeout
    }

    public func check(provider: Provider, secret: Secret?) async throws -> CompatibilityResult {
        // Routed providers are reached through the local adapter proxy: probe the
        // URL Codex actually uses (e.g. Anthropic has no /v1/responses upstream).
        let base: URL
        if let port = CodexConfigGenerator.proxyPort(for: provider.id) {
            base = URL(string: "http://127.0.0.1:\(port)/v1")!
        } else {
            base = provider.baseURL
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
        let body: [String: Any] = [
            "model": provider.defaultModel,
            "input": "ping",
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await client.send(request)
        } catch {
            return CompatibilityResult(
                state: .incompatible(reason: "Cannot reach \(provider.displayName): \(error.localizedDescription)"),
                detail: error.localizedDescription
            )
        }
        let code = response.statusCode
        Log.info("Compatibility probe for \(provider.displayName) -> HTTP \(code) at \(endpoint.absoluteString)")
        // Some gateways (Z.ai notably) answer HTTP 200 with an error object in
        // the body for a rejected key, e.g. {"code":401,"msg":"token expired or
        // incorrect","success":false} or {"code":1000,"msg":"Authentication
        // Failed"}. A 2xx must not be treated as "connected" in that case.
        if let authFailure = Self.embeddedAuthFailure(data: data) {
            Log.info("Compatibility probe for \(provider.displayName) -> embedded auth failure (HTTP \(code))")
            return CompatibilityResult(
                state: .incompatible(reason: "\(provider.displayName) a refusé la clé : \(authFailure)"),
                detail: "HTTP \(code) auth"
            )
        }
        switch code {
        case 200...299:
            return CompatibilityResult(state: .compatible, detail: "HTTP \(code)")
        case 401, 403:
            return CompatibilityResult(
                state: .incompatible(reason: "\(provider.displayName) rejected the key (HTTP \(code))"),
                detail: "HTTP \(code)"
            )
        case 404, 405:
            return CompatibilityResult(
                state: .incompatible(reason: "\(provider.displayName) does not expose /v1/responses (HTTP \(code))"),
                detail: "HTTP \(code)"
            )
        default:
            // 4xx/5xx other than the above still means the endpoint exists.
            return CompatibilityResult(state: .compatible, detail: "HTTP \(code)")
        }
    }

    /// Detects an authentication failure hidden inside an otherwise successful
    /// HTTP response. Handles both Z.ai's flat `{"code":401,"msg":…}` shape and
    /// the OpenAI-compatible `{"error":{"code":"401","message":…}}` shape.
    static func embeddedAuthFailure(data: Data) -> String? {
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
                return message?.isEmpty == false ? message : "code \(codeString)"
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
            return message
        }
        return nil
    }
}
