import Foundation
import SweetCookieKit

public enum TencentTokenPlanProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    static let cookieEnvironmentKey = "TENCENT_TOKEN_PLAN_COOKIE"
    private static let credentials = ProviderCredentialAdapter(
        environmentProjections: [.cookieHeader(cookieEnvironmentKey, onlyWhenManual: true)],
        authDetector: { environment, _ in
            CookieHeaderNormalizer.normalize(environment[Self.cookieEnvironmentKey]) == nil ? [] : ["web"]
        })

    static func makeDescriptor() -> ProviderDescriptor {
        #if os(macOS)
        let browserOrder: BrowserCookieImportOrder? = [.chrome]
        #else
        let browserOrder: BrowserCookieImportOrder? = nil
        #endif
        return ProviderDescriptor(
            id: .tencenttokenplan,
            settingsSection: .init(
                TencentTokenPlanProviderSettingsKey.self,
                cookieSettings: TencentTokenPlanProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .tencenttokenplan,
                displayName: "Tencent Token Plan",
                shortDisplayName: "Tencent",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Tencent Token Plan usage",
                cliName: "tencent-token-plan",
                defaultEnabled: false,
                widgetSelectable: false,
                browserCookieOrder: browserOrder,
                dashboardURL: TencentTokenPlanUsageFetcher.dashboardURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .tencenttokenplan),
                iconResourceName: "ProviderIcon-tencenttokenplan",
                color: ProviderColor(hex: 0x006EFF)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Tencent Token Plan cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    context.settings?.tencentTokenPlan?.cookieSource == .off ? [] : [TencentTokenPlanWebFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "tencent-token-plan",
                aliases: ["tencent", "tencenttokenplan"],
                versionDetector: nil,
                browserSupportExemption: { source, environment, settings in
                    guard source == .auto || source == .web,
                          settings?.tencentTokenPlan?.cookieSource != .off else { return false }
                    if settings?.tencentTokenPlan?.cookieSource == .manual {
                        return CookieHeaderNormalizer.normalize(settings?.tencentTokenPlan?.manualCookieHeader) != nil
                    }
                    return CookieHeaderNormalizer.normalize(environment?[self.cookieEnvironmentKey]) != nil
                }))
    }
}

struct TencentTokenPlanWebFetchStrategy: ProviderFetchStrategy {
    let id = "tencent-token-plan.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.tencentTokenPlan?.cookieSource != .off else { return false }
        if Self.override(context) != nil { return true }
        if context.settings?.tencentTokenPlan?.cookieSource == .manual { return false }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.settings?.tencentTokenPlan?.cookieSource != .off else {
            throw TencentTokenPlanError.missingCookies
        }
        if let header = Self.override(context) {
            let usage = try await TencentTokenPlanUsageFetcher.fetchUsage(cookieHeader: header)
            return self.makeResult(usage: usage, sourceLabel: "web")
        }
        guard context.settings?.tencentTokenPlan?.cookieSource != .manual else {
            throw TencentTokenPlanError.missingCookies
        }
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .tencenttokenplan) {
            do {
                let usage = try await TencentTokenPlanUsageFetcher.fetchUsage(cookieHeader: cached.cookieHeader)
                return self.makeResult(usage: usage, sourceLabel: "web")
            } catch TencentTokenPlanError.sessionExpired {
                CookieHeaderCache.clear(provider: .tencenttokenplan)
            }
        }
        guard Self.allowsBrowserImport(context) else { throw TencentTokenPlanError.missingCookies }
        let sessions = try TencentTokenPlanCookieImporter.sessions(browserDetection: context.browserDetection)
        for session in sessions {
            do {
                let usage = try await TencentTokenPlanUsageFetcher.fetchUsage(cookieHeader: session.header)
                CookieHeaderCache.store(
                    provider: .tencenttokenplan, cookieHeader: session.header, sourceLabel: session.label)
                return self.makeResult(usage: usage, sourceLabel: "web")
            } catch TencentTokenPlanError.sessionExpired {
                continue
            }
        }
        throw sessions.isEmpty ? TencentTokenPlanError.missingCookies : TencentTokenPlanError.sessionExpired
        #else
        throw TencentTokenPlanError.missingCookies
        #endif
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func override(_ context: ProviderFetchContext) -> String? {
        let settings = context.settings?.tencentTokenPlan
        guard settings?.cookieSource != .off else { return nil }
        if settings?.cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(settings?.manualCookieHeader)
        }
        return CookieHeaderNormalizer.normalize(context.env[TencentTokenPlanProviderDescriptor.cookieEnvironmentKey])
    }

    static func allowsBrowserImport(_ context: ProviderFetchContext) -> Bool {
        context.runtime == .app && ProviderInteractionContext.current == .userInitiated &&
            (context.settings?.tencentTokenPlan?.cookieSource ?? .auto) == .auto
    }
}
