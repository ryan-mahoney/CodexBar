import Foundation

public struct TencentTokenPlanProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum TencentTokenPlanProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.tencenttokenplan
    public typealias Section = TencentTokenPlanProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias TencentTokenPlanProviderSettings = CodexBarCore.TencentTokenPlanProviderSettings
    public var tencentTokenPlan: TencentTokenPlanProviderSettings? {
        self[TencentTokenPlanProviderSettingsKey.self]
    }

    public static func make(tencentTokenPlan: TencentTokenPlanProviderSettings?) -> Self {
        self.make(tencentTokenPlan, for: TencentTokenPlanProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func tencentTokenPlan(_ section: TencentTokenPlanProviderSettings) -> Self {
        Self(section, for: TencentTokenPlanProviderSettingsKey.self)
    }
}
