import CodexBarCore
import Foundation

enum ReportKind: String, Codable, Sendable {
    case subscription
    case balance
}

struct ReportRequest: Sendable, Equatable {
    let provider: UsageProvider
    let kind: ReportKind
}

struct ReportWindow: Codable, Sendable, Equatable {
    let name: String
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
}

struct ReportBalance: Codable, Sendable, Equatable {
    let amount: Double
    let currency: String
}

struct ReportRow: Codable, Sendable, Equatable {
    let provider: String
    let account: String
    let kind: ReportKind
    let windows: [ReportWindow]
    let balances: [ReportBalance]
    let unavailable: String?

    static func failure(_ request: ReportRequest, account: String, reason: String) -> Self {
        Self(
            provider: request.provider.rawValue,
            account: account,
            kind: request.kind,
            windows: [],
            balances: [],
            unavailable: reason)
    }

    static func project(_ result: ProviderFetchResult, request: ReportRequest, account: String) -> Self {
        let usage = result.usage
        if request.kind == .balance {
            // A budget remainder or a token-credit count is not a monetary balance.
            guard let cost = usage.providerCost, let balance = cost.balance,
                  balance.isFinite, Locale.commonISOCurrencyCodes.contains(cost.currencyCode)
            else { return .failure(request, account: account, reason: "balance unavailable") }
            return Self(
                provider: request.provider.rawValue,
                account: account,
                kind: request.kind,
                windows: [],
                balances: [ReportBalance(amount: balance, currency: cost.currencyCode)],
                unavailable: nil)
        }
        let metadata = ProviderDescriptorRegistry.descriptor(for: request.provider).metadata
        var candidates: [(String, RateWindow?, Bool)] = [
            (metadata.sessionLabel, usage.primary, true),
            (metadata.weeklyLabel, usage.secondary, true),
            (metadata.opusLabel ?? "Additional", usage.tertiary, true),
        ]
        candidates += (usage.extraRateWindows ?? []).map { ($0.title, Optional($0.window), $0.usageKnown) }
        let windows = candidates.compactMap { name, optionalWindow, known -> ReportWindow? in
            guard let window = optionalWindow, !window.isSyntheticPlaceholder else { return nil }
            let percent = known && window.usedPercent.isFinite && window.usedPercent >= 0
                ? window.usedPercent : nil
            return ReportWindow(
                name: name,
                usedPercent: percent,
                windowMinutes: window.windowMinutes,
                resetsAt: window.resetsAt)
        }
        let incomplete = windows.isEmpty || windows.contains { $0.usedPercent == nil }
        return Self(
            provider: request.provider.rawValue,
            account: account,
            kind: request.kind,
            windows: windows,
            balances: [],
            unavailable: incomplete ? "quota unavailable" : nil)
    }
}

struct CapacityReport: Codable, Sendable {
    let checkedAt: Date
    let accounts: [ReportRow]

    var isComplete: Bool {
        !self.accounts.isEmpty && self.accounts.allSatisfy { $0.unavailable == nil }
    }

    func text() -> String {
        let date = ISO8601DateFormatter()
        var lines = ["Checked: \(date.string(from: self.checkedAt))"]
        for row in self.accounts {
            let name = "\(row.provider) [\(Self.safeText(row.account))]"
            for window in row.windows {
                let duration = window.windowMinutes.map { " (\($0) min)" } ?? ""
                let used = window.usedPercent.map { String(format: "%.1f%% used", $0) } ?? "unavailable"
                let reset = window.resetsAt.map { date.string(from: $0) } ?? "unknown"
                lines.append("\(name): \(Self.safeText(window.name))\(duration), \(used), resets \(reset)")
            }
            for balance in row.balances {
                lines.append("\(name): \(balance.currency) \(String(format: "%.2f", balance.amount)) remaining")
            }
            if let reason = row.unavailable {
                lines.append("\(name): \(row.kind.rawValue) unavailable (\(reason))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func safeText(_ value: String) -> String {
        String(String.UnicodeScalarView(
            value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160)))
    }
}
