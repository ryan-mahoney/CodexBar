import Foundation

#if os(macOS)
import SweetCookieKit

enum TencentTokenPlanCookieImporter {
    struct Session {
        let header: String
        let label: String
    }

    static func sessions(browserDetection: BrowserDetection) throws -> [Session] {
        let order: BrowserCookieImportOrder = [.chrome]
        let query = BrowserCookieQuery(domains: ["tencentcloud.com"])
        var sessions: [Session] = []
        for browser in order.cookieImportCandidates(using: browserDetection) {
            let stores: [BrowserCookieStoreRecords]
            do {
                stores = try BrowserCookieClient().codexBarRecords(matching: query, in: browser)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                throw TencentTokenPlanError.missingCookies
            }
            // Never mix account cookies from different Chrome profiles.
            let groups = Dictionary(grouping: stores, by: { $0.store.profile.id })
            let orderedGroups = groups.values.sorted { ($0.map(\.label).min() ?? "") < ($1.map(\.label).min() ?? "") }
            for group in orderedGroups {
                let records = group.flatMap(\.records)
                let cookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
                guard let header = self.header(cookies: cookies),
                      (try? TencentTokenPlanUsageFetcher.request(cookieHeader: header)) != nil else { continue }
                sessions.append(Session(header: header, label: group.map(\.label).min() ?? "Chrome"))
            }
        }
        return sessions
    }

    static func header(cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let url = TencentTokenPlanUsageFetcher.endpoint
        let host = url.host!
        let matches = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches = domain.hasPrefix(".")
                ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
                : host == domain
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = url.path == path || url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            return domainMatches && pathMatches && (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
            if lhs.domain.count != rhs.domain.count { return lhs.domain.count > rhs.domain.count }
            return (lhs.expiresDate ?? .distantFuture) > (rhs.expiresDate ?? .distantFuture)
        }
        var names = Set<String>()
        let pairs = matches.filter { names.insert($0.name).inserted }.map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}
#endif
