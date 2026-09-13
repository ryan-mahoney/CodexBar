import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TencentTokenPlanError: LocalizedError, Equatable {
    case missingCookies
    case sessionExpired
    case noActivePlan
    case malformedResponse
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingCookies:
            "Sign in to Tencent Cloud in Chrome, then refresh, or paste a console Cookie header in settings."
        case .sessionExpired:
            "Your Tencent Cloud session expired. Sign in again and refresh your cookies."
        case .noActivePlan:
            "No active Singapore Personal Token Plan was found in this Tencent Cloud account."
        case .malformedResponse:
            "Tencent Cloud returned an unrecognized Token Plan response."
        case .requestFailed:
            "Tencent Cloud could not load Token Plan usage. Try again or open the console."
        }
    }
}

public enum TencentTokenPlanUsageFetcher {
    public static let dashboardURL = URL(string: "https://console.tencentcloud.com/tokenhub/tokenplan")!
    static let endpoint = URL(string: "https://console.tencentcloud.com/cgi/capi")!
    static let action = "DescribeTokenPlanPersonalPackage"

    static func fetchUsage(
        cookieHeader: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        let response = try await transport.response(for: self.request(cookieHeader: cookieHeader))
        if [301, 302, 303, 307, 308, 401, 403].contains(response.statusCode) {
            throw TencentTokenPlanError.sessionExpired
        }
        guard response.statusCode == 200 else { throw TencentTokenPlanError.requestFailed }
        return try self.parse(response.data)
    }

    static func request(cookieHeader: String, now: Date = Date()) throws -> URLRequest {
        guard let header = CookieHeaderNormalizer.normalize(cookieHeader),
              !header.contains("\r"), !header.contains("\n") else { throw TencentTokenPlanError.missingCookies }
        let pairs = CookieHeaderNormalizer.pairs(from: header)
        func cookie(_ name: String) -> String? {
            pairs.first { $0.name == name }?.value
        }
        guard let session = cookie("skey") ?? cookie("p_skey"), !session.isEmpty,
              let rawUin = cookie("uin"), !rawUin.isEmpty else { throw TencentTokenPlanError.missingCookies }
        let uin = rawUin.filter { $0.isASCII && $0.isNumber }
        guard !uin.isEmpty else { throw TencentTokenPlanError.missingCookies }
        let owner = (cookie("ownerUin") ?? "0").filter { $0.isASCII && $0.isNumber }
        var components = URLComponents(url: self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "delegate"),
            URLQueryItem(name: "cmd", value: self.action),
            URLQueryItem(name: "serviceType", value: "tokenhub"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "secure", value: "1"),
            URLQueryItem(name: "sts", value: "1"),
            URLQueryItem(name: "t", value: String(Int64(now.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "uin", value: uin),
            URLQueryItem(name: "ownerUin", value: owner.isEmpty ? "0" : owner),
            URLQueryItem(name: "csrfCode", value: String(self.csrfCode(session: session))),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(self.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://console.tencentcloud.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "regionId": 9,
            "serviceType": "tokenhub",
            "cmd": self.action,
            "data": ["Version": "2026-03-22", "ProductType": "personal", "Language": "en-US"],
        ])
        return request
    }

    /// Tencent's console hashes the decoded session key using JavaScript UTF-16 code units.
    static func csrfCode(session: String) -> UInt32 {
        let decoded = session.removingPercentEncoding ?? session
        return decoded.utf16.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) } & 0x7FFF_FFFF
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = self.number(root["code"]) else { throw TencentTokenPlanError.malformedResponse }
        // Observed console response for an expired international session (mccode also 50).
        if code == 50 { throw TencentTokenPlanError.sessionExpired }
        guard code == 0 else { throw TencentTokenPlanError.requestFailed }
        guard let outer = root["data"] as? [String: Any] else { throw TencentTokenPlanError.malformedResponse }
        if let nestedCode = self.number(outer["code"]), nestedCode != 0 {
            throw TencentTokenPlanError.requestFailed
        }
        let payload = outer["data"] as? [String: Any] ?? outer
        guard let package = payload["Response"] as? [String: Any] else {
            throw TencentTokenPlanError.malformedResponse
        }
        if package["Error"] != nil { throw TencentTokenPlanError.requestFailed }
        guard let status = package["PackageStatus"] as? String else {
            throw TencentTokenPlanError.malformedResponse
        }
        if ["UNPURCHASED", "FAILED", "ISOLATED", "DESTROYED"].contains(status) {
            throw TencentTokenPlanError.noActivePlan
        }
        guard ["ACTIVE", "USED_UP"].contains(status) else { throw TencentTokenPlanError.requestFailed }
        guard let total = self.number(package["TotalCredits"]), total > 0,
              let used = self.number(package["TotalUsed"]), used >= 0
        else {
            throw TencentTokenPlanError.malformedResponse
        }
        let tiers = [
            "sv_lmp_tokenplan_eh_lite": "Lite",
            "sv_lmp_tokenplan_eh_standard": "Standard",
            "sv_lmp_tokenplan_eh_pro": "Pro",
            "sv_lmp_tokenplan_eh_max": "Max",
        ]
        let tier = (package["PrepayInquiryKey"] as? String).flatMap { tiers[$0] }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let primary = RateWindow(
            usedPercent: min(1, used / total) * 100,
            windowMinutes: nil,
            resetsAt: self.date(package["PeriodEndDate"] as? String),
            resetDescription: "\(used.formatted(format)) / \(total.formatted(format)) credits used")
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .tencenttokenplan,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: tier.map { "Personal – \($0)" } ?? "Personal"))
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double? = if let string = value as? String {
            Double(string)
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            value.doubleValue
        } else {
            nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        return iso.date(from: raw)
    }
}
