import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CapacityReportTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func result(_ usage: UsageSnapshot) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "fixture",
            strategyID: "fixture",
            strategyKind: .apiToken)
    }

    @Test
    func `report is a separate command with explicit selections`() throws {
        let invocation = try Program(descriptors: CodexBarCLI.commandDescriptors()).resolve(argv: [
            "report", "--subscriptions", "codex,claude", "--balances", "deepseek", "--json",
        ])
        #expect(invocation.path == ["report"])
        #expect(invocation.parsedValues.flags.contains("json"))
        let requests = try CodexBarCLI.reportRequests(subscriptions: "codex, claude,codex", balances: "deepseek")
        #expect(requests.map(\.provider) == [.codex, .claude, .deepseek])
        #expect(requests.map(\.kind) == [.subscription, .subscription, .balance])
    }

    @Test
    func `empty and unsupported selections fail before account access`() {
        for (subscriptions, balances) in [
            (nil, nil),
            ("", nil),
            ("codex,", nil),
            ("all", nil),
            (nil, "codex"),
            ("deepseek", nil),
        ] as [(String?, String?)] {
            #expect(throws: CLIArgumentError.self) {
                try CodexBarCLI.reportRequests(subscriptions: subscriptions, balances: balances)
            }
        }
    }

    @Test
    func `each initial subscription provider resolves`() throws {
        let requests = try CodexBarCLI.reportRequests(
            subscriptions: "codex,claude,zai,qwencloud,alibaba-token-plan", balances: nil)
        #expect(requests.count == 5)
    }

    @Test
    func `quotas preserve all windows without replacing missing data with zero`() {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: Self.now, resetDescription: nil),
            secondary: RateWindow(usedPercent: 110, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [NamedRateWindow(
                id: "specific",
                title: "Model limit",
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: Self.now,
                    resetDescription: nil),
                usageKnown: false)],
            updatedAt: Self.now)
        let row = ReportRow.project(
            Self.result(usage),
            request: .init(provider: .codex, kind: .subscription),
            account: "work")
        #expect(row.windows.map(\.usedPercent) == [0, 110, nil])
        #expect(row.windows[1].resetsAt == nil)
        #expect(row.unavailable != nil)
        #expect(row.balances.isEmpty)
    }

    @Test
    func `synthetic or missing quotas are unavailable`() {
        for window in [nil, RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)]
        {
            let row = ReportRow.project(
                Self.result(UsageSnapshot(primary: window, secondary: nil, updatedAt: Self.now)),
                request: .init(provider: .claude, kind: .subscription),
                account: "current")
            #expect(row.windows.isEmpty)
            #expect(row.unavailable != nil)
        }
    }

    @Test
    func `balance remains money and never becomes a budget remainder`() {
        for (balance, currency, expected) in [
            (0.0, "USD", true),
            (-2.0, "CNY", true),
            (nil, "USD", false),
            (99.0, "credits", false),
        ]
            as [(Double?, String, Bool)]
        {
            let cost = ProviderCostSnapshot(
                used: 10,
                limit: 100,
                currencyCode: currency,
                balance: balance,
                updatedAt: Self.now)
            let row = ReportRow.project(
                Self.result(UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    providerCost: cost,
                    updatedAt: Self.now)),
                request: .init(
                    provider: .deepseek,
                    kind: .balance),
                account: "API")
            #expect((row.unavailable == nil) == expected)
            #expect(row.balances.first?.amount == (expected ? balance : nil))
            #expect(row.windows.isEmpty)
        }
    }

    @Test
    func `DeepSeek uses the existing typed snapshot only in report mode`() {
        let snapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "CNY",
            totalBalance: 12.34,
            grantedBalance: 2,
            toppedUpBalance: 10.34,
            updatedAt: Self.now)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
        ProviderReportMode.$isActive.withValue(true) {
            let cost = snapshot.toUsageSnapshot().providerCost
            #expect(cost?.balance == 12.34)
            #expect(cost?.currencyCode == "CNY")
        }
    }

    @Test
    func `parallel collection preserves order and keeps failures visible`() async throws {
        let requests = try CodexBarCLI.reportRequests(subscriptions: "claude,codex", balances: "deepseek")
        let collector = ReportCollector { request in
            if request.provider == .claude { try? await Task.sleep(for: .milliseconds(15)) }
            return [
                .failure(request, account: "first", reason: "fixture"),
                .failure(request, account: "second", reason: "fixture"),
            ]
        }
        let report = await collector.collect(requests, now: { Self.now })
        #expect(report.accounts.map(\.provider) == ["claude", "claude", "codex", "codex", "deepseek", "deepseek"])
        #expect(!report.isComplete)
        #expect(report.checkedAt == Self.now)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CapacityReport.self, from: data)
        #expect(decoded.accounts == report.accounts)
    }

    @Test
    func `HTTP report configuration retains no responses cookies or credentials`() {
        let config = ProviderReportMode.httpConfiguration()
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        ProviderReportMode.$isActive.withValue(true) {
            #expect(ProviderHTTPClient.defaultConfiguration().urlCache == nil)
            // These operations must return before accessing any preferences or cache location.
            #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: "fixture-token") == nil)
            ClaudeOAuthUsageRateLimitGate.recordRateLimit(accessToken: "fixture-token", retryAfter: Self.now)
            ClaudeOAuthUsageRateLimitGate.recordSuccess(accessToken: "fixture-token")
            #expect(OpenAIDashboardCacheStore.load() == nil)
            OpenAIDashboardCacheStore.clear()
        }
    }

    @Test
    func `terminal report removes control characters and excludes unrelated fields`() {
        let row = ReportRow(
            provider: "deepseek",
            account: "API\n\u{001B}[31m",
            kind: .balance,
            windows: [],
            balances: [ReportBalance(amount: 0, currency: "USD")],
            unavailable: nil)
        let report = CapacityReport(checkedAt: Self.now, accounts: [row])
        #expect(report.isComplete)
        #expect(!report.text().contains("\u{001B}"))
        #expect(report.text().contains("USD 0.00 remaining"))
        #expect(!report.text().contains("history"))
    }
}
