import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A one-shot quota/balance read. Authentication remains owned by the existing integrations.
/// Response caches and persisted quota observations are not part of this path.
public enum ProviderReportMode {
    @TaskLocal public static var isActive = false

    public static func httpConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
