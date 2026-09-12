import CodexBarCore
import Foundation

struct ReportDatePresentation {
    let now: Date
    let timeZone: TimeZone

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.timeZone
        return calendar
    }

    func timestamp(_ date: Date) -> String {
        self.format(date, pattern: "MMM d, yyyy 'at' h:mm a z")
    }

    func reset(_ date: Date) -> String {
        let day: String
        if self.calendar.isDate(date, inSameDayAs: self.now) {
            day = "today"
        } else if let tomorrow = self.calendar.date(byAdding: .day, value: 1, to: self.now),
                  self.calendar.isDate(date, inSameDayAs: tomorrow)
        {
            day = "tomorrow"
        } else {
            let sameYear = self.calendar.component(.year, from: date) == self.calendar.component(.year, from: self.now)
            day = self.format(date, pattern: sameYear ? "EEE, MMM d" : "EEE, MMM d, yyyy")
        }
        let difference = date.timeIntervalSince(self.now)
        let duration = self.duration(abs(difference))
        let relative = difference > 0 ? "in \(duration)" : "\(duration) ago"
        return "\(day) at \(self.format(date, pattern: "h:mm a z")) (\(relative))"
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = self.calendar
        formatter.timeZone = self.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than 1m" }
        let minutes = Int(min(seconds / 60, 525_600_000))
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

enum ReportSetupGuidance {
    static func lines(provider: String, command: String, config: CodexBarConfig) -> [String] {
        let executable = "'" + command.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        switch provider {
        case "zai":
            let region = config.providerConfig(for: UsageProvider.zai.instanceID)?.sanitizedRegion
            let url = region == "bigmodel-cn"
                ? "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"
                : "https://z.ai/manage-apikey/apikey-list"
            return Self.apiKeyLines(provider: provider, executable: executable, url: url) + [
                "Use a key from the account with your Coding Plan. This integration does not use browser sign-in.",
                "For a saved token account, update that account's key instead of the provider-wide key.",
            ]
        case "deepseek":
            return [
                "A failed request does not prove that you are signed out. If no valid key is configured:",
                "Open https://platform.deepseek.com/api_keys and copy your API key.",
                "In this terminal, run: export DEEPSEEK_API_KEY=\"$(pbpaste)\"",
                "The API key is enough for the balance report. Chrome session access is not required.",
                "Run the report again in this terminal. Repeat the export in a new terminal.",
                "For persistent storage, use DeepSeek's API tokens section in CodexBar settings.",
                "Treat the key as a password. Do not paste it into chat.",
                "If a valid key still fails, check the network and provider service.",
            ]
        case "qwencloud":
            return [
                "Open https://home.qwencloud.com/billing/subscription/token-plan-individual in your signed-in Chrome profile.",
            ] + Self.cookieLines(
                variable: "QWEN_CLOUD_COOKIE",
                request: "the quota/usage request to cs-data.qwencloud.com")
        case "alibabatokenplan":
            let region = config.providerConfig(for: UsageProvider.alibabatokenplan.instanceID)?.sanitizedRegion
                .flatMap(AlibabaTokenPlanAPIRegion.init(rawValue:)) ?? .chinaMainland
            return [
                "Configured region: \(region.rawValue).",
                "Open \(region.dashboardURL.absoluteString) in your signed-in Chrome profile.",
                "The region must match your account and plan: intl, cn, intl-personal, or cn-personal.",
                "Set providers[].region for id alibabatokenplan in your CodexBar configuration if it does not match.",
            ] + Self.cookieLines(variable: "ALIBABA_TOKEN_PLAN_COOKIE", request: "the token-plan quota/usage request")
        case "codex":
            return ["Refresh the affected account's login in Codex, then run the report again."]
        case "claude":
            return ["Refresh the affected account's login in Claude Code, then run the report again."]
        default:
            return []
        }
    }

    private static func apiKeyLines(provider: String, executable: String, url: String) -> [String] {
        [
            "A failed request does not prove that you are signed out. If no valid key is configured:",
            "Open \(url) and copy your API key.",
            "Save the copied key locally: pbpaste | \(executable) config set-api-key --provider \(provider) --stdin",
            "This saves a credential, not report data. Do not paste the key into chat.",
            "Run the report again. If a valid key still fails, check the network and provider service.",
        ]
    }

    private static func cookieLines(variable: String, request: String) -> [String] {
        [
            "Chrome sign-in alone does not guarantee that this executable can read Chrome's encrypted cookies.",
            "For a manual handoff, open Chrome DevTools > Network, then reload the page.",
            "Select \(request). Under Headers > Request Headers, copy only the Cookie value.",
            "In this terminal, run: export \(variable)=\"$(pbpaste)\"",
            "Run the report again in this terminal.",
            "The cookie stays in this shell until you unset it or close the terminal.",
            "Treat the cookie as a password. Do not paste it into chat. Repeat the handoff when the session expires.",
            "If the reading still fails, check the selected plan, region, network, and provider service.",
        ]
    }
}
