import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CapacityReportPresentationTests {
    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    @Test
    func `reset times show local clock time and time remaining`() throws {
        let presentation = try ReportDatePresentation(
            now: self.date("2026-09-12T14:50:48Z"),
            timeZone: #require(TimeZone(identifier: "America/New_York")))
        #expect(presentation.timestamp(presentation.now) == "Sep 12, 2026 at 10:50 AM EDT")
        #expect(try presentation.reset(self.date("2026-09-12T17:39:00Z")) == "today at 1:39 PM EDT (in 2h 48m)")
        #expect(try presentation.reset(self.date("2026-09-16T17:59:00Z")) == "Wed, Sep 16 at 1:59 PM EDT (in 4d 3h)")
        #expect(try presentation.reset(self.date("2026-09-12T14:49:48Z")) == "today at 10:49 AM EDT (1m ago)")
    }

    @Test
    func `tomorrow follows the local calendar rather than UTC`() throws {
        let presentation = try ReportDatePresentation(
            now: self.date("2026-09-13T03:30:00Z"),
            timeZone: #require(TimeZone(identifier: "America/New_York")))
        #expect(try presentation.reset(self.date("2026-09-13T04:30:00Z")) == "tomorrow at 12:30 AM EDT (in 1h 0m)")
    }

    @Test
    func `reset timezone follows daylight saving at the reset instant`() throws {
        let presentation = try ReportDatePresentation(
            now: self.date("2026-11-01T05:10:00Z"),
            timeZone: #require(TimeZone(identifier: "America/New_York")))
        #expect(try presentation.reset(self.date("2026-11-01T05:30:00Z")) == "today at 1:30 AM EDT (in 20m)")
        #expect(try presentation.reset(self.date("2026-11-01T06:30:00Z")) == "today at 1:30 AM EST (in 1h 20m)")
        #expect(try presentation.reset(self.date("2027-01-03T12:00:00Z")).contains("Jan 3, 2027 at 7:00 AM EST"))
    }

    @Test
    func `setup instructions describe credential handoff not just browser login`() {
        let config = CodexBarConfig.makeDefault()
        for provider in ["zai"] {
            let lines = ReportSetupGuidance.lines(provider: provider, command: "/tmp/report tool", config: config)
            #expect(lines.joined()
                .contains("pbpaste | '/tmp/report tool' config set-api-key --provider \(provider) --stdin"))
            #expect(lines.joined().contains("does not prove that you are signed out"))
            #expect(lines.joined().contains("https://"))
        }
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .zai))
        let deepseek = ReportSetupGuidance.lines(provider: "deepseek", command: "codexbar", config: config).joined()
        #expect(deepseek.contains("export DEEPSEEK_API_KEY=\"$(pbpaste)\""))
        #expect(!deepseek.contains("set-api-key"))
        #expect(DeepSeekSettingsReader.apiKey(environment: ["DEEPSEEK_API_KEY": "fixture-key"]) == "fixture-key")
        for (provider, variable) in [
            ("qwencloud", "QWEN_CLOUD_COOKIE"),
            ("alibabatokenplan", "ALIBABA_TOKEN_PLAN_COOKIE"),
        ] {
            let text = ReportSetupGuidance.lines(provider: provider, command: "codexbar", config: config).joined()
            #expect(text.contains("Request Headers"))
            #expect(text.contains("export \(variable)=\"$(pbpaste)\""))
            #expect(text.contains("session expires"))
        }
    }

    @Test
    func `setup links follow the configured provider region`() {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .zai, region: "bigmodel-cn"),
            ProviderConfig(id: .alibabatokenplan, region: "intl-personal"),
        ])
        let zai = ReportSetupGuidance.lines(provider: "zai", command: "codexbar", config: config).joined()
        #expect(zai.contains("https://bigmodel.cn/"))
        #expect(!zai.contains("https://z.ai/"))
        let alibaba = ReportSetupGuidance.lines(provider: "alibabatokenplan", command: "codexbar", config: config)
            .joined()
        #expect(alibaba.contains("Configured region: intl-personal"))
        #expect(alibaba.contains(AlibabaTokenPlanAPIRegion.internationalPersonal.dashboardURL.absoluteString))
    }

    @Test
    func `setup command quotes shell metacharacters in executable paths`() {
        let text = ReportSetupGuidance.lines(
            provider: "zai",
            command: "/tmp/reader's $(test)/codexbar",
            config: .makeDefault()).joined()
        #expect(text.contains("'/tmp/reader'\"'\"'s $(test)/codexbar' config set-api-key"))
    }

    @Test
    func `report shows setup once per failed provider without changing JSON readings`() throws {
        let now = try self.date("2026-09-12T14:50:48Z")
        let failure = ReportRow.failure(
            .init(provider: .deepseek, kind: .balance),
            account: "current",
            reason: "timeout")
        let report = CapacityReport(checkedAt: now, accounts: [failure, failure])
        let text = report.text()
        #expect(text.components(separatedBy: "deepseek — setup / troubleshooting:").count == 2)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: encoder.encode(report), encoding: .utf8))
        #expect(json.contains("2026-09-12T14:50:48Z"))
        #expect(!json.contains("pbpaste"))
        #expect(!json.contains("api_keys"))
    }
}
