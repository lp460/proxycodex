import XCTest
@testable import AIProviderSwitcherCore

final class ProviderUsageServiceTests: XCTestCase {
    private let url = URL(string: "https://example.invalid/usage")!

    private func service(
        _ response: Result<(HTTPURLResponse, Data), Error>,
        localize: @escaping @Sendable (String) -> String = { $0 }
    ) -> ProviderUsageService {
        ProviderUsageService(
            client: MockHTTPClient(responses: [response]),
            localize: localize
        )
    }

    private func response(_ status: Int, _ payload: String) -> Result<(HTTPURLResponse, Data), Error> {
        .success((MockHTTPClient.makeResponse(url: url, status: status), Data(payload.utf8)))
    }

    func testDeepSeekBalanceParsesUSDBalance() async throws {
        let body = """
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"1.00"},
          {"currency":"USD","total_balance":"18.42","granted_balance":"2.00","topped_up_balance":"16.42"}
        ]}
        """
        let snapshot = try await service(response(200, body)).snapshot(
            for: ProviderCatalog.default[id: "deepseek"]!,
            secret: Secret("sk-test-value-123")
        )
        XCTAssertEqual(snapshot.status, ProviderUsageStatus.available)
        XCTAssertEqual(snapshot.balance?.available, Decimal(string: "18.42"))
        XCTAssertEqual(snapshot.balance?.granted, Decimal(string: "2.00"))
        XCTAssertEqual(snapshot.balance?.toppedUp, Decimal(string: "16.42"))
        XCTAssertEqual(snapshot.balance?.currency, "USD")
    }

    func testDeepSeekUnavailableDoesNotHideBalance() async throws {
        let body = #"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"9.50"}]}"#
        let snapshot = try await service(response(200, body)).snapshot(
            for: ProviderCatalog.default[id: "deepseek"]!,
            secret: Secret("sk-test-value-123")
        )
        XCTAssertEqual(snapshot.status, ProviderUsageStatus.unavailable)
        XCTAssertEqual(snapshot.balance?.available, Decimal(string: "9.50"))
        XCTAssertEqual(snapshot.note, "Les appels API ne sont plus disponibles.")
    }

    func testOpenRouterParsesKeyBudgetAndUsage() async throws {
        let body = """
        {"data":{"limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
                 "usage":25.5,"usage_daily":1.2,"usage_weekly":8.4,"usage_monthly":25.5}}
        """
        let snapshot = try await service(response(200, body)).snapshot(
            for: ProviderCatalog.default[id: "openrouter"]!,
            secret: Secret("sk-or-v1-test-value")
        )
        XCTAssertEqual(snapshot.balance?.label, "Budget de la clé")
        XCTAssertEqual(snapshot.balance?.available, Decimal(string: "74.5"))
        XCTAssertEqual(snapshot.balance?.total, 100)
        XCTAssertTrue(snapshot.note?.contains("7 jours : 8.4 $") == true)
        XCTAssertTrue(snapshot.note?.contains("Reset : monthly") == true)
    }

    func testUsageLabelsAndNotesUseInjectedLocalizer() async throws {
        let body = """
        {"data":{"limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
                 "usage":25.5,"usage_daily":1.2,"usage_weekly":8.4,"usage_monthly":25.5}}
        """
        let translations = [
            "Budget de la clé": "Key budget",
            "Aujourd'hui : %@ $": "Today: $%@",
            "7 jours : %@ $": "7 days: $%@",
            "Ce mois : %@ $": "This month: $%@",
            "Reset : %@": "Reset: %@"
        ]
        let snapshot = try await service(response(200, body)) { key in
            translations[key] ?? key
        }.snapshot(
            for: ProviderCatalog.default[id: "openrouter"]!,
            secret: Secret("sk-or-v1-test-value")
        )

        XCTAssertEqual(snapshot.balance?.label, "Key budget")
        XCTAssertEqual(
            snapshot.note,
            "Today: $1.2 · 7 days: $8.4 · This month: $25.5 · Reset: monthly"
        )
    }

    func testOpenRouterWithoutLimitShowsKnownUsageOnly() async throws {
        let body = #"{"data":{"limit":null,"usage":25.5,"usage_daily":1.2}}"#
        let snapshot = try await service(response(200, body)).snapshot(
            for: ProviderCatalog.default[id: "openrouter"]!,
            secret: Secret("sk-or-v1-test-value")
        )
        XCTAssertNil(snapshot.balance?.available)
        XCTAssertNil(snapshot.balance?.total)
        XCTAssertEqual(snapshot.balance?.used, Decimal(string: "25.5"))
        XCTAssertEqual(snapshot.status, ProviderUsageStatus.available)
    }

    func testZAITokenWindowParsesAndUnknownTypesDoNotBreak() throws {
        let object: [String: Any] = ["data": [
            ["type": "TOKENS_LIMIT", "label": "Token usage (5 Hour)", "percentage": 22],
            ["type": "TIME_LIMIT", "percentage": 10, "windowDurationMins": 43200],
            ["type": "BRAND_NEW_UNKNOWN_LIMIT", "percentage": 42]
        ]]
        let snapshot = ZAIUsageParser.snapshot(from: object, providerID: "glm")
        XCTAssertEqual(snapshot.status, ProviderUsageStatus.available)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 22)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertTrue(snapshot.windows.contains { $0.durationMinutes == 43200 })
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertEqual(snapshot.windows.first?.detail, "Reset non exposé par Z.ai")
    }

    func testZAITypeKeyedFixtureIsTolerant() throws {
        let object: [String: Any] = ["data": [
            "TOKENS_LIMIT": ["percentage": 28, "label": "Token usage (5 Hour)"]
        ]]
        let snapshot = ZAIUsageParser.snapshot(from: object, providerID: "glm")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 28)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
    }

    func testOpenCodeGoParsesRollingWeeklyAndMonthlyWindows() async throws {
        let body = """
        {"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-09-12T01:54:20.610Z"},
                  "weekly":{"status":"ok","percent":34,"resetsAt":"2026-09-14T00:00:00.610Z"},
                  "monthly":{"status":"rate-limited","percent":100,
                             "resetsAt":"2026-10-11T18:13:18.610Z"}}}
        """
        let snapshot = try await service(response(200, body)).snapshot(
            for: ProviderCatalog.default[id: "opencode-go"]!,
            secret: Secret("sk-go-test-value-123")
        )
        XCTAssertEqual(snapshot.status, ProviderUsageStatus.available)
        XCTAssertEqual(snapshot.planLabel, "OpenCode Go")
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12, 34, 100])
        XCTAssertEqual(snapshot.windows.last?.detail, "Limite atteinte")
    }

    func testCodexWindowsAreIdentifiedByDurationNotPosition() throws {
        func payload(primary: Int, secondary: Int?) -> [String: Any] {
            var limits: [String: Any] = ["primary": [
                "usedPercent": primary == 300 ? 31.0 : 46.0, "windowDurationMins": primary
            ]]
            if let secondary {
                limits["secondary"] = ["usedPercent": secondary == 300 ? 31.0 : 46.0, "windowDurationMins": secondary]
            }
            return ["result": ["rateLimitsByLimitId": ["codex": ["rateLimits": limits]]]]
        }
        let first = CodexUsageParser.snapshot(from: payload(primary: 300, secondary: 10_080))
        let second = CodexUsageParser.snapshot(from: payload(primary: 10_080, secondary: 300))

        XCTAssertEqual(first.windows.map(\.label), second.windows.map(\.label))
        XCTAssertEqual(first.windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(first.windows.map(\.remainingPercent), [69, 54])
    }

    func testCodexSingleWeeklyWindowDoesNotInventFiveHours() throws {
        let response: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": 31, "windowDurationMins": 10_080],
            "secondary": NSNull()
        ]]]
        let snapshot = CodexUsageParser.snapshot(from: response)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.label, "7 jours")
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 69)
    }

    func testCodexResetIsUnixSeconds() throws {
        let date = CodexUsageParser.date(NSNumber(value: 1_900_000_000))
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(UsageWindow(id: "0", label: "x", usedPercent: 0).remainingPercent, 100)
        XCTAssertEqual(UsageWindow(id: "31", label: "x", usedPercent: 31).remainingPercent, 69)
        XCTAssertEqual(UsageWindow(id: "100", label: "x", usedPercent: 100).remainingPercent, 0)
        XCTAssertEqual(UsageWindow(id: "110", label: "x", usedPercent: 110).remainingPercent, 0)
    }

    func testHTTPAndInvalidResponsesBecomeControlledErrors() async {
        for status in [401, 403, 500] {
            do {
                _ = try await service(response(status, "{}")).snapshot(
                    for: ProviderCatalog.default[id: "deepseek"]!, secret: Secret("sk-error-test-123"))
                XCTFail("expected HTTP \(status) failure")
            } catch let error as ProviderUsageError {
                XCTAssertEqual(error, .http(status))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }

        do {
            _ = try await service(response(200, "{invalid")).snapshot(
                for: ProviderCatalog.default[id: "deepseek"]!, secret: Secret("sk-error-test-123"))
            XCTFail("expected invalid response")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTimeoutAndMissingKeysDoNotCrash() async throws {
        do {
            _ = try await service(.failure(URLError(.timedOut))).snapshot(
                for: ProviderCatalog.default[id: "deepseek"]!, secret: Secret("sk-timeout-test"))
            XCTFail("expected timeout")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .timeout)
        }

        let noKey = try await service(.failure(URLError(.timedOut))).snapshot(
            for: ProviderCatalog.default[id: "deepseek"]!, secret: nil)
        XCTAssertEqual(noKey.status, ProviderUsageStatus.authenticationRequired)
    }
}
