import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Apple Search Ads (AdServices) attribution token provider.
///
/// Captures the token locally via `AAAttribution.attributionToken()` (iOS 14.3+). The SDK NEVER
/// resolves the token against api-adservices.apple.com — the backend does that, fast, because the
/// token is valid for only a few minutes. Returns nil when unavailable (simulator, < iOS 14.3,
/// or a transient Apple error) — never throws.
enum AdServicesTokenProvider {
    static func token() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }
}
