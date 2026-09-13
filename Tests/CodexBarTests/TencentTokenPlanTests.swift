import Foundation
import Testing
@testable import CodexBarCore

struct TencentTokenPlanTests {
    /// Synthetic values using the international console's Personal Package contract.
    private func fixture(_ overrides: [String: Any] = [:], nested: Bool = true) throws -> Data {
        var package: [String: Any] = [
            "PackageStatus": "ACTIVE",
            "TotalCredits": "7900",
            "TotalUsed": "1975",
            "CycleCredits": "2600",
            "PeriodEndDate": "2026-10-13T00:00:00Z",
            "ExpireTime": "2027-09-13T00:00:00Z",
            "PrepayInquiryKey": "sv_lmp_tokenplan_eh_standard",
        ]
        package.merge(overrides) { _, new in new }
        let payload: [String: Any] = ["Response": package]
        return try JSONSerialization.data(withJSONObject: [
            "code": 0,
            "data": nested ? ["code": 0, "data": payload] : payload,
        ])
    }

    @Test(arguments: [true, false])
    func `maps total credits rather than cycle credits and uses period reset`(nested: Bool) throws {
        let usage = try TencentTokenPlanUsageFetcher.parse(self.fixture(nested: nested))
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.providerID == .tencenttokenplan)
        #expect(usage.identity?.loginMethod == "Personal – Standard")
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z"))
        #expect(usage.primary?.resetDescription?.contains("credits used") == true)
    }

    @Test
    func `accepts numeric credits and clamps exhausted gauge without losing raw usage`() throws {
        let usage = try TencentTokenPlanUsageFetcher.parse(self.fixture([
            "PackageStatus": "USED_UP", "TotalCredits": 100, "TotalUsed": 125,
        ]))
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription?.contains("125") == true)
    }

    @Test(arguments: ["NaN", "Infinity", "-1", "", "invalid"])
    func `rejects malformed usage instead of reporting zero`(value: String) throws {
        let data = try self.fixture(["TotalUsed": value])
        #expect(throws: TencentTokenPlanError.malformedResponse) { try TencentTokenPlanUsageFetcher.parse(data) }
    }

    @Test
    func `rejects absent boolean and zero quota fields`() throws {
        for fields: [String: Any] in [
            ["TotalCredits": 0], ["TotalCredits": true], ["TotalUsed": NSNull()], ["TotalUsed": false],
        ] {
            let data = try self.fixture(fields)
            #expect(throws: TencentTokenPlanError.malformedResponse) { try TencentTokenPlanUsageFetcher.parse(data) }
        }
    }

    @Test(arguments: ["UNPURCHASED", "FAILED", "ISOLATED", "DESTROYED"])
    func `inactive packages produce an actionable error`(status: String) throws {
        let data = try self.fixture(["PackageStatus": status])
        #expect(throws: TencentTokenPlanError.noActivePlan) { try TencentTokenPlanUsageFetcher.parse(data) }
    }

    @Test
    func `does not invent a reset or plan tier`() throws {
        let usage = try TencentTokenPlanUsageFetcher.parse(self.fixture([
            "PeriodEndDate": "unknown", "PrepayInquiryKey": "future-plan",
        ]))
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.identity?.loginMethod == "Personal")
    }

    @Test
    func `preserves explicit reset offsets and omits ambiguous timestamps`() throws {
        let usage = try TencentTokenPlanUsageFetcher.parse(self.fixture([
            "PeriodEndDate": "2026-10-13T08:00:00.000+08:00",
        ]))
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z"))
        let ambiguous = try TencentTokenPlanUsageFetcher.parse(self.fixture([
            "PeriodEndDate": "2026-10-13 08:00:00",
        ]))
        #expect(ambiguous.primary?.resetsAt == nil)
    }

    @Test
    func `expired session and API errors never become a healthy balance`() throws {
        let expired = Data(#"{"code":50,"mccode":50,"msg":"session expired"}"#.utf8)
        #expect(throws: TencentTokenPlanError.sessionExpired) { try TencentTokenPlanUsageFetcher.parse(expired) }
        let error = Data(#"{"code":0,"data":{"Response":{"Error":{"Code":"InternalError"}}}}"#.utf8)
        #expect(throws: TencentTokenPlanError.requestFailed) { try TencentTokenPlanUsageFetcher.parse(error) }
        #expect(throws: TencentTokenPlanError.malformedResponse) {
            try TencentTokenPlanUsageFetcher.parse(Data("<html>Sign in</html>".utf8))
        }
    }

    @Test
    func `request uses Singapore Personal quota endpoint and decoded session CSRF`() throws {
        let request = try TencentTokenPlanUsageFetcher.request(cookieHeader: "Cookie: skey=a%2Bb; uin=o00123")
        #expect(request.url?.host == "console.tencentcloud.com")
        #expect(request.url?.path == "/cgi/capi")
        #expect(request.httpMethod == "POST")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "skey=a%2Bb; uin=o00123")
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "csrfCode" }?.value == "193484147")
        #expect(items.first { $0.name == "uin" }?.value == "00123")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["regionId"] as? Int == 9)
        #expect(json["cmd"] as? String == "DescribeTokenPlanPersonalPackage")
        #expect((json["data"] as? [String: String])?["ProductType"] == "personal")
        #expect((json["data"] as? [String: String])?["Version"] == "2026-03-22")
    }

    @Test(arguments: ["sk-inference-key", "skey=session", "skey=; uin=123", "skey=session; uin=invalid"])
    func `rejects incomplete cookies and inference keys`(header: String) {
        #expect(throws: TencentTokenPlanError.missingCookies) {
            try TencentTokenPlanUsageFetcher.request(cookieHeader: header)
        }
    }

    @Test
    func `fetches through injected transport and surfaces HTTP authentication failures`() async throws {
        let fixture = try self.fixture()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (fixture, response)
        }
        let usage = try await TencentTokenPlanUsageFetcher.fetchUsage(
            cookieHeader: "skey=session; uin=123", transport: transport)
        #expect(usage.primary?.usedPercent == 25)
        let denied = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        await #expect(throws: TencentTokenPlanError.sessionExpired) {
            try await TencentTokenPlanUsageFetcher.fetchUsage(cookieHeader: "skey=x; uin=123", transport: denied)
        }
    }

    private func context(source: ProviderCookieSource, manual: String? = nil) -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["TENCENT_TOKEN_PLAN_COOKIE": "skey=environment; uin=1"],
            settings: .make(tencentTokenPlan: .init(cookieSource: source, manualCookieHeader: manual)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
            browserDetection: browser)
    }

    @Test
    func `manual and off modes never fall through to environment or browser cookies`() {
        #expect(TencentTokenPlanWebFetchStrategy.override(self.context(source: .off)) == nil)
        #expect(TencentTokenPlanWebFetchStrategy.override(self.context(source: .manual)) == nil)
        #expect(TencentTokenPlanWebFetchStrategy.override(self.context(source: .auto)) == "skey=environment; uin=1")
        let manual = self.context(source: .manual, manual: "skey=manual; uin=2")
        #expect(TencentTokenPlanWebFetchStrategy.override(manual) == "skey=manual; uin=2")
        #expect(!TencentTokenPlanWebFetchStrategy.allowsBrowserImport(self.context(source: .auto)))
        ProviderInteractionContext.$current.withValue(.userInitiated) {
            #expect(TencentTokenPlanWebFetchStrategy.allowsBrowserImport(self.context(source: .auto)))
            #expect(!TencentTokenPlanWebFetchStrategy.allowsBrowserImport(manual))
            #expect(!TencentTokenPlanWebFetchStrategy.allowsBrowserImport(self.context(source: .off)))
        }
    }

    #if os(macOS)
    @Test
    func `imported cookie headers exclude unrelated expired and wrong path cookies`() throws {
        let now = Date()
        func cookie(_ name: String, domain: String, path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "test", .domain: domain, .path: path,
            ]
            if let expires { properties[.expires] = expires }
            return try #require(HTTPCookie(properties: properties))
        }
        let cookies = try [
            cookie("skey", domain: ".tencentcloud.com"),
            cookie("uin", domain: "console.tencentcloud.com"),
            cookie("wronghost", domain: "not-tencentcloud.com"),
            cookie("wrongpath", domain: ".tencentcloud.com", path: "/cg"),
            cookie("expired", domain: ".tencentcloud.com", expires: now - 1),
        ]
        let header = try #require(TencentTokenPlanCookieImporter.header(cookies: cookies, now: now))
        #expect(Set(CookieHeaderNormalizer.pairs(from: header).map(\.name)) == ["skey", "uin"])
    }
    #endif
}
