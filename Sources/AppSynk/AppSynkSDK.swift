import Foundation
import AppTrackingTransparency
#if canImport(UIKit)
import UIKit
#endif

/// Main entry point for the AppSynk iOS SDK.
/// All public methods are thread-safe and can be called from any thread.
public final class AppSynkSDK {

    // MARK: - Internal state

    private static var _shared: AppSynkSDK?
    private static let queue = DispatchQueue(label: "io.appsynk.sdk", attributes: .concurrent)

    private let apiKey: String
    private let options: AppSynkOptions
    let eventQueue: EventQueue
    let attributionService: AttributionService
    let networkService: NetworkService

    // Collects the device + attribution blocks. Static fields are captured once at configure()
    // (main thread); dynamic fields (networkType, IDFA) are re-read on each collect().
    private let deviceCollector: DeviceDataCollector

    /// GDPR consent + anonymization state (persisted, thread-safe).
    private let privacy: PrivacyManager

    private var userId: String?
    private var userProperties: [String: Any] = [:]

    /// Automatic lifecycle events + session state. Created in configure() (see bootLifecycle()).
    private var lifecycle: LifecycleTracker?

    /// Deep linking: URL handling, resolution, buffering/replay, attribution access. See bootLifecycle().
    private var deepLinks: DeepLinkResolver?

    // MARK: - Initializer (private — always called from main thread via configure)

    private init(apiKey: String, options: AppSynkOptions) {
        self.apiKey = apiKey
        self.options = options
        self.deviceCollector = DeviceDataCollector()  // safe: static fields captured on main thread via configure()
        self.networkService = NetworkService(apiKey: apiKey, options: options)
        self.attributionService = AttributionService()
        self.eventQueue = EventQueue(network: networkService, options: options, storeURL: EventQueue.defaultStoreURL())
        self.privacy = PrivacyManager(anonymizeByDefault: options.anonymizeUserByDefault)

        // Restore persisted state (survives app restarts, cleared only by reset())
        self.userId = UserDefaults.standard.string(forKey: "appsynk:userId")
        if let stored = UserDefaults.standard.dictionary(forKey: "appsynk:userProps") {
            self.userProperties = stored
        }
    }

    // MARK: - Public API

    /// Configure and initialize the AppSynk SDK.
    /// Call once from `application(_:didFinishLaunchingWithOptions:)` or `App.init()`.
    /// Must be called from the **main thread**.
    public static func configure(apiKey: String, options: AppSynkOptions? = nil) {
        let opts = options ?? AppSynkOptions()
        let instance = AppSynkSDK(apiKey: apiKey, options: opts)
        queue.async(flags: .barrier) { _shared = instance }

        if opts.logLevel != .none {
            print("[AppSynk] SDK configured. Environment: \(opts.environment)")
        }

        instance.bootLifecycle()
        Task { await instance.eventQueue.start() }
        Task { await instance.validateConfiguration() }
    }

    /// Track a custom event.
    public static func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        guard let sdk = shared else {
            print("[AppSynk] Warning: SDK not configured. Call AppSynkSDK.configure() first.")
            return
        }
        Task { await sdk.enqueueEvent(name: name, properties: properties ?? [:]) }
    }

    /// Track a purchase event with mandatory orderId for 24-hour deduplication.
    /// Duplicate orderIds within 24 hours are silently dropped.
    public static func trackRevenue(
        amount: Double,
        currency: String,
        productId: String,
        orderId: String,
        receipt: Data? = nil
    ) {
        // Dedup via a single capped index (orderId -> last-seen timestamp). Entries older than the
        // 24h window are purged on every write, so it never grows unbounded (no key-per-order).
        let indexKey = "appsynk:dedupIndex"
        let storedIndex = (UserDefaults.standard.dictionary(forKey: indexKey) as? [String: Double]) ?? [:]
        let (isDuplicate, updatedIndex) = Self.dedupOrder(orderId, now: Date().timeIntervalSince1970, index: storedIndex)
        UserDefaults.standard.set(updatedIndex, forKey: indexKey)

        if isDuplicate {
            shared.map { sdk in
                if sdk.options.logLevel != .none {
                    print("[AppSynk] Skipping duplicate purchase — orderId already seen: \(orderId)")
                }
            }
            return
        }

        var props: [String: Any] = [
            "amount":     amount,
            "currency":   currency,
            "product_id": productId,
            "order_id":   orderId
        ]
        if let receipt { props["receipt"] = receipt.base64EncodedString() }

        trackEvent("purchase", properties: props)

        // SKAdNetwork: server-piloted conversion value. The dev only ever controls disableSKAdNetwork.
        guard let sdk = shared, !sdk.options.disableSKAdNetwork else { return }
        Task { await sdk.applySkanValue(amount: amount, currency: currency, eventType: "purchase") }
    }

    /// Pure dedup decision over the order index: purges entries older than `window`, then reports
    /// whether `orderId` was already seen within it. Returns the updated (purged) index to persist.
    static func dedupOrder(
        _ orderId: String,
        now: TimeInterval,
        index: [String: Double],
        window: TimeInterval = 86_400
    ) -> (isDuplicate: Bool, updatedIndex: [String: Double]) {
        var purged = index.filter { now - $0.value < window }
        if let seen = purged[orderId], now - seen < window {
            return (true, purged)
        }
        purged[orderId] = now
        return (false, purged)
    }

    /// Track an ad impression revenue event.
    public static func trackAdRevenue(
        network: String,
        amount: Double,
        currency: String,
        adUnit: String? = nil,
        adType: String? = nil
    ) {
        var props: [String: Any] = [
            "network":  network,
            "amount":   amount,
            "currency": currency
        ]
        if let adUnit { props["ad_unit"] = adUnit }
        if let adType { props["ad_type"] = adType }
        trackEvent("ad_revenue", properties: props)
    }

    /// Persist a user identifier. Included in every subsequent event.
    /// Survives app restarts until `reset()` is called.
    public static func setUserId(_ userId: String) {
        UserDefaults.standard.set(userId, forKey: "appsynk:userId")
        queue.async(flags: .barrier) { _shared?.userId = userId }
    }

    /// Merge additional user properties. Persisted across app restarts.
    /// Attached to every subsequent event under the top-level `user` key.
    public static func setUserProperties(_ properties: [String: Any]) {
        // Merge into persisted dict
        var merged = UserDefaults.standard.dictionary(forKey: "appsynk:userProps") ?? [:]
        merged.merge(properties) { _, new in new }
        UserDefaults.standard.set(merged, forKey: "appsynk:userProps")

        queue.async(flags: .barrier) {
            _shared?.userProperties.merge(properties) { _, new in new }
        }
    }

    /// Reset user identity and properties.
    /// Clears userId and userProperties, but preserves the stable device_id.
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: "appsynk:userId")
        UserDefaults.standard.removeObject(forKey: "appsynk:userProps")
        // Intentionally NOT removing appsynk_device_id — it must remain stable.

        queue.async(flags: .barrier) {
            _shared?.userId = nil
            _shared?.userProperties = [:]
            _shared?.lifecycle?.resetSession()
        }
        AttributionService.clearStoredAttribution()
    }

    /// Declare the user's GDPR consent. Persisted and attached (root `consent`) to every event.
    public static func setConsent(
        isUserSubjectToGDPR: Bool,
        hasConsentForDataUsage: Bool,
        hasConsentForAdsPersonalization: Bool
    ) {
        shared?.privacy.setConsent(
            isUserSubjectToGDPR: isUserSubjectToGDPR,
            hasConsentForDataUsage: hasConsentForDataUsage,
            hasConsentForAdsPersonalization: hasConsentForAdsPersonalization)
    }

    /// Enable/disable anonymized mode: strips IDFA/IDFV (and other identifiers) from events and marks
    /// them `isAnonymized`. Persisted across launches.
    public static func anonymizeUser(_ enabled: Bool) {
        shared?.privacy.setAnonymized(enabled)
    }

    /// Request the ATT prompt. The SDK never shows it implicitly — call this once the app has fully
    /// presented its UI (after onboarding). The gated `install` event then carries the IDFA if granted.
    public static func requestTrackingAuthorization(
        completion: @escaping (ATTrackingManager.AuthorizationStatus) -> Void
    ) {
        ATTManager.requestTrackingAuthorization(completion: completion)
    }

    // MARK: - Deep Linking

    /// Call from `application(_:open:options:)` in AppDelegate.
    /// Handles `appsynk://` custom-scheme URLs from your tracking links.
    public static func handleOpenURL(_ url: URL) {
        shared?.deepLinks?.handleOpenURL(url)
    }

    /// Call from `application(_:continue:restorationHandler:)` in AppDelegate.
    /// Handles `https://go.appsynk.io/{linkId}` universal links.
    public static func handleUniversalLink(_ userActivity: NSUserActivity) {
        shared?.deepLinks?.handleUniversalLink(userActivity)
    }

    /// Register a callback to receive deep link attribution data.
    /// If data is already available (link resolved before this call), fires immediately.
    /// - Parameter callback: Called on the main thread with attribution or nil on failure.
    public static func getDeepLinkData(callback: @escaping (AttributionData?) -> Void) {
        shared?.deepLinks?.getDeepLinkData(callback)
    }

    /// Returns the best-known attribution — the resolved deep link if any, else organic.
    /// Fires on the main thread; immediately when data is already available.
    public static func getAttributionData(callback: @escaping (AttributionData?) -> Void) {
        shared?.deepLinks?.getAttributionData(callback)
    }

    // MARK: - Private helpers

    static var shared: AppSynkSDK? { queue.sync { _shared } }

    private func enqueueEvent(name: String, properties: [String: Any], adServicesToken: String? = nil) async {
        let event = buildEvent(name: name, properties: properties, adServicesToken: adServicesToken)
        await eventQueue.enqueue(event)
    }

    private func buildEvent(name: String, properties: [String: Any], adServicesToken: String? = nil) -> AppSynkEvent {
        let deviceId = getOrCreateDeviceId()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"

        // The backend event has no dedicated user/session fields, so persisted identity/profile and
        // the current session id are folded into properties (where the backend stores everything).
        var enrichedProperties = properties
        let (currentUserId, currentUserProps) = AppSynkSDK.queue.sync {
            (self.userId, self.userProperties)
        }
        var userDict = currentUserProps
        if let currentUserId { userDict["id"] = currentUserId }
        if !userDict.isEmpty { enrichedProperties["user"] = userDict }
        if let sessionId = lifecycle?.currentSessionId { enrichedProperties["sessionId"] = sessionId }

        // Fresh device + attribution snapshot — networkType and IDFA reflect the current moment.
        let deviceData = deviceCollector.collect(options: options, adServicesToken: adServicesToken)
        var attribution = deviceData.attribution
        attribution.clickId = attributionService.clickId   // overlay the deep-link click id when present

        // Privacy: strip identifiers when anonymized; attach the declared GDPR consent.
        let anonymized = privacy.isAnonymized
        if anonymized { attribution = attribution.anonymizedCopy() }

        return AppSynkEvent(
            deviceId: deviceId,
            appId: appId,
            eventName: name,
            timestamp: Date(),
            platform: AppSynkConstants.platform,
            osVersion: Self.osVersionString(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            device: deviceData.device,
            attribution: attribution,
            properties: enrichedProperties,
            consent: privacy.consent,
            isAnonymized: anonymized
        )
    }

    /// Creates and starts the lifecycle tracker (install/reinstall/session/app_open/app_update).
    /// Called from configure() once the instance exists, so capturing self is safe.
    private func bootLifecycle() {
        let tracker = LifecycleTracker(
            options: options,
            track: { [weak self] name, properties, adServicesToken in
                await self?.enqueueEvent(name: name, properties: properties, adServicesToken: adServicesToken)
            },
            postAdServicesToken: { [weak self] token in
                await self?.sendAdServicesToken(token)
            }
        )
        lifecycle = tracker
        tracker.start()

        deepLinks = DeepLinkResolver(
            network: networkService,
            attributionStore: attributionService,
            track: { [weak self] name, properties in
                await self?.enqueueEvent(name: name, properties: properties)
            },
            markOpenSource: { [weak self] source in
                self?.lifecycle?.markOpenSource(source)
            },
            logLevel: options.logLevel
        )
    }

    /// Non-blocking startup validation: GET /v1/sdk/init?bundleId=. Logs the resolved plan/env on
    /// success and a clear warning on a key/bundleId mismatch — it never crashes the app.
    private func validateConfiguration() async {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        guard !bundleId.isEmpty else { return }
        do {
            let info = try await networkService.sdkInit(bundleId: bundleId)
            if options.logLevel == .debug {
                print("[AppSynk] sdk/init OK — app=\(info.appName), plan=\(info.plan), environment=\(info.environment)")
            }
        } catch {
            guard options.logLevel != .none else { return }
            switch error {
            case NetworkError.unauthorized:
                print("[AppSynk] ⚠️ sdk/init: invalid API key (401). Check your ak_live_ / ak_sandbox_ key.")
            case let NetworkError.serverError(code) where code == 404:
                print("[AppSynk] ⚠️ sdk/init: bundleId '\(bundleId)' not found for this key (404). " +
                      "Verify the bundleId registered in the dashboard and that you're using the matching live/sandbox key.")
            default:
                print("[AppSynk] sdk/init validation could not complete: \(error.localizedDescription)")
            }
        }
    }

    /// Posts the AdServices token to the backend's dedicated exchange endpoint. Best-effort: the
    /// token is short-lived, so a failure is logged, not retried through the event queue.
    private func sendAdServicesToken(_ token: String) async {
        let deviceId = getOrCreateDeviceId()
        let appId = Bundle.main.bundleIdentifier ?? "unknown"
        do {
            try await networkService.postAdServicesToken(deviceId: deviceId, appId: appId, token: token)
        } catch {
            if options.logLevel != .none {
                print("[AppSynk] AdServices token post failed: \(error.localizedDescription)")
            }
        }
    }

    /// SKAdNetwork backend piloting: fetch the server-computed conversion value for a revenue event
    /// and apply it (best-effort). Internal — the dev never sees this, only disableSKAdNetwork.
    private func applySkanValue(amount: Double, currency: String, eventType: String) async {
        do {
            let response = try await networkService.skanValue(amount: amount, currency: currency, eventType: eventType)
            let coarse = SKAdNetworkManager.coarseName(forTier: response.revenueTier)
            SKAdNetworkManager.shared.updateConversionValue(
                fine: response.conversionValue, coarse: coarse, lockWindow: false, source: "backend")
        } catch {
            if options.logLevel != .none {
                print("[AppSynk] SKAN value fetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func getOrCreateDeviceId() -> String {
        // Single source of truth for the stable install instance id (thread-safe, same key).
        DeviceIdentity.installInstanceId()
    }

    /// OS version string — UIKit where available, ProcessInfo elsewhere (so the module also
    /// compiles for macOS / CI without UIKit).
    private static func osVersionString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// Pretty-printed JSON of the current device + attribution blocks (debug only).
    func debugDeviceDataJSON() -> String {
        let data = deviceCollector.collect(options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data),
              let json = String(data: encoded, encoding: .utf8) else {
            return "<device data encoding failed>"
        }
        return json
    }

}

// MARK: - Debug Interface

public extension AppSynkSDK {

    /// Debug utilities for integration testing. Not for production use.
    static let debug = DebugInterface()

    final class DebugInterface {

        /// Simulate an install event with hardcoded source/campaign and att_status=authorized.
        /// Useful for testing attribution pipelines in sandbox mode.
        public func simulateInstall(source: String = "debug", campaign: String = "test_campaign") {
            AppSynkSDK.trackEvent("install", properties: [
                "referrer":   "direct",
                "source":     source,
                "campaign":   campaign,
                "att_status": "authorized",
                "is_debug":   true
            ])
            print("[AppSynk.debug] Simulated install — source: \(source), campaign: \(campaign)")
        }

        /// Simulate a revenue event with a random orderId (bypasses deduplication).
        public func simulateRevenue(amount: Double = 0.99, currency: String = "USD") {
            let orderId = UUID().uuidString
            AppSynkSDK.trackRevenue(
                amount: amount,
                currency: currency,
                productId: "debug.product.001",
                orderId: orderId
            )
            print("[AppSynk.debug] Simulated revenue — amount: \(amount) \(currency), orderId: \(orderId)")
        }

        /// Verify network connectivity and API key validity.
        /// - Parameter completion: Called on the main thread with success response or error.
        public func testConnection(completion: @escaping (Result<String, Error>) -> Void) {
            guard let sdk = AppSynkSDK.shared else {
                completion(.failure(DebugError.sdkNotConfigured))
                return
            }
            Task {
                do {
                    let pong = try await sdk.networkService.ping()
                    await MainActor.run { completion(.success("\(pong.status) (\(pong.environment))")) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
        }

        /// Print the current device + attribution blocks as pretty JSON.
        public func dumpDeviceData() {
            guard let sdk = AppSynkSDK.shared else {
                print("[AppSynk.debug] SDK not configured."); return
            }
            print("[AppSynk.debug] DeviceData:\n\(sdk.debugDeviceDataJSON())")
        }

        /// Print the pending event queue — count + event names.
        public func dumpQueue() {
            guard let sdk = AppSynkSDK.shared else {
                print("[AppSynk.debug] SDK not configured."); return
            }
            Task {
                let count = await sdk.eventQueue.count
                let names = await sdk.eventQueue.pendingEventNames
                print("[AppSynk.debug] Queue: \(count) pending — [\(names.joined(separator: ", "))]")
            }
        }
    }

    enum DebugError: Error, LocalizedError {
        case sdkNotConfigured

        public var errorDescription: String? {
            "AppSynk SDK not configured. Call AppSynkSDK.configure() first."
        }
    }
}
