import Foundation

/// SDK-wide constants. Single source of truth for base URLs and the SDK version, so a release
/// bump or a host change is a one-line edit referenced everywhere.
public enum AppSynkConstants {

    /// SDK semantic version. Bump on each release — sent as the `X-SDK-Version` request header and
    /// anywhere the SDK reports its own version.
    public static let sdkVersion = "1.0.1"

    /// Platform identifier — sent as the `X-SDK-Platform` header and as `platform` on every event.
    public static let platform = "ios"

    /// Production API base URL.
    public static let productionBaseURL = URL(string: "https://api.appsynk.io")!

    /// Sandbox API base URL. Identical to production: the backend routes sandbox vs live from
    /// the API key prefix (`ak_sandbox_` / `ak_live_`), not from the host. Kept as a distinct
    /// constant so a future split (e.g. a sandbox subdomain) is a one-line change.
    public static let sandboxBaseURL = URL(string: "https://api.appsynk.io")!
}
