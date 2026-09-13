import CodexBarCore
import Foundation

extension SettingsStore {
    var tencentTokenPlanCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .tencenttokenplan)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .tencenttokenplan) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .tencenttokenplan, field: "cookieHeader", value: newValue)
        }
    }

    var tencentTokenPlanCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .tencenttokenplan, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .tencenttokenplan) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .tencenttokenplan, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func tencentTokenPlanSettingsSnapshot() -> ProviderSettingsSnapshot.TencentTokenPlanProviderSettings {
        ProviderSettingsSnapshot.TencentTokenPlanProviderSettings(
            cookieSource: self.tencentTokenPlanCookieSource,
            manualCookieHeader: self.tencentTokenPlanCookieHeader)
    }
}
