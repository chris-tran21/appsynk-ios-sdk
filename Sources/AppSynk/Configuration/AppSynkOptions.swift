import Foundation

/// Configuration for the AppSynk SDK.
///
/// Mirrors the Android `AppSynkOptions` — same names, same defaults, same toggles — so the
/// React Native / Flutter / Unity bridges stay trivial. Pass an instance to
/// `AppSynkSDK.configure(apiKey:options:)`.
public struct AppSynkOptions {

    // MARK: - Nested types

    /// API environment. Production and sandbox share the same host: the backend detects
    /// sandbox mode from the API key prefix (`ak_sandbox_` / `ak_live_`), not from the URL.
    public enum Environment {
        case production
        case sandbox

        /// Default base URL for this environment. Single source of truth: `AppSynkConstants`.
        var baseUrl: URL {
            switch self {
            case .production: return AppSynkConstants.productionBaseURL
            case .sandbox:    return AppSynkConstants.sandboxBaseURL
            }
        }
    }

    /// Console logging verbosity. `.debug` is the most verbose.
    public enum LogLevel {
        case none
        case error
        case debug
    }

    // MARK: - Core

    /// API environment. Use `.sandbox` (with an `ak_sandbox_` key) for testing.
    public var environment: Environment = .production

    /// Custom API base URL. Overrides the environment host — e.g. for data residency or a
    /// self-hosted gateway (à la AppsFlyer `setHost`). Leave `nil` to use the default endpoint.
    public var customApiUrl: URL? = nil

    /// How much the SDK logs to the console.
    public var logLevel: LogLevel = .none

    /// Seconds of inactivity after which a resumed app starts a new session.
    public var sessionTimeout: TimeInterval = 1800

    /// Number of events to accumulate before flushing to the API.
    public var batchSize: Int = 10

    /// Seconds between automatic flushes, even when `batchSize` hasn't been reached.
    public var flushInterval: TimeInterval = 30

    /// Flush events while backgrounded using a background task.
    public var sendInBackground: Bool = true

    /// How long the SDK waits for the user's ATT decision before sending the gated `install`
    /// event. The install fires when ATT resolves OR this timeout elapses, whichever comes
    /// first — so the IDFA is included whenever the user grants it.
    public var attWaitTimeout: TimeInterval = 60

    // MARK: - Privacy toggles (all opt-out, default false)

    /// Never read or send the IDFA, even when ATT is authorized.
    public var disableIdfa: Bool = false

    /// Never read or send the IDFV.
    public var disableIdfv: Bool = false

    /// Never fetch or send the Apple Search Ads (AdServices) attribution token.
    public var disableAdServices: Bool = false

    /// Never register with — or update — SKAdNetwork / AdAttributionKit.
    public var disableSKAdNetwork: Bool = false

    /// Start every install in anonymized mode (identifiers stripped) until consent is granted.
    public var anonymizeUserByDefault: Bool = false

    // MARK: - Request signing (optional HMAC-SHA256)

    /// Shared secret for HMAC-SHA256 request signing. `nil` disables signing.
    public var hmacSecretKey: String? = nil

    /// Key identifier sent with the signature so the backend can select the matching secret.
    public var hmacKeyId: String? = nil

    public init() {}
}
