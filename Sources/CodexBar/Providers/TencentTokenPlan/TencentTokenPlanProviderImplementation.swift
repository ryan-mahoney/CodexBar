import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct TencentTokenPlanProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .tencenttokenplan

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.tencentTokenPlanCookieSource
        _ = settings.tencentTokenPlanCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .tencentTokenPlan(context.settings.tencentTokenPlanSettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.tencentTokenPlanCookieSource.rawValue },
            set: { raw in
                context.settings.tencentTokenPlanCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.tencentTokenPlanCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Singapore Personal Edition. Import your console session from Chrome.",
                manual: "Paste a Cookie header from console.tencentcloud.com.",
                off: "Tencent Token Plan cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "tencent-token-plan-cookie-source",
                title: "Cookie source",
                subtitle: "Singapore Personal Edition. Import your console session from Chrome.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.loadForDisplay(provider: .tencenttokenplan) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "tencent-token-plan-cookie",
                title: "Cookie header",
                subtitle: "Use your Singapore console session. Inference API keys cannot read plan usage.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.tencentTokenPlanCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "tencent-token-plan-open-dashboard",
                        title: "Open Token Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(TencentTokenPlanUsageFetcher.dashboardURL)
                        }),
                ],
                isVisible: {
                    context.settings.tencentTokenPlanCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
