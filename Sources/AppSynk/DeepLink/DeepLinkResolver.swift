import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Buffers deep-link attribution that resolves BEFORE a callback is registered, then replays it.
///
/// This is the AppsFlyer pattern (the `isBridgeReady` / `AF_BRIDGE_SET` buffer) that prevents lost
/// deep links at cold start — and that naive bridges get wrong. It's the groundwork for the Phase 2
/// RN / Flutter / Unity bridges.
final class DeepLinkBuffer {
    private let queue = DispatchQueue(label: "io.appsynk.deeplink")
    private var resolved: AttributionData?
    private var callbacks: [(AttributionData?) -> Void] = []

    init(seed: AttributionData? = nil) { self.resolved = seed }

    /// Fire immediately (main thread) if already resolved; otherwise buffer until resolution.
    func register(_ callback: @escaping (AttributionData?) -> Void) {
        queue.async {
            if let resolved = self.resolved {
                DispatchQueue.main.async { callback(resolved) }
            } else {
                self.callbacks.append(callback)
            }
        }
    }

    /// Resolution arrived: store it and replay every buffered callback on the main thread.
    func deliver(_ data: AttributionData) {
        queue.async {
            self.resolved = data
            let pending = self.callbacks
            self.callbacks.removeAll()
            DispatchQueue.main.async { pending.forEach { $0(data) } }
        }
    }

    /// Current best-known attribution (does not buffer); completion fires on the main thread.
    func current(_ completion: @escaping (AttributionData?) -> Void) {
        queue.async {
            let resolved = self.resolved
            DispatchQueue.main.async { completion(resolved) }
        }
    }
}

/// Deep linking: URL handling, backend resolution, buffering/replay, attribution access, and
/// re-engagement tracking.
final class DeepLinkResolver {
    typealias TrackHandler = (_ name: String, _ properties: [String: Any]) async -> Void

    private static let persistKey = "appsynk:deepLinkAttribution"
    static let universalHost = "go.appsynk.io"
    static let customScheme  = "appsynk"

    private let buffer: DeepLinkBuffer
    private let network: NetworkService
    private let attributionStore: AttributionService
    private let track: TrackHandler
    private let markOpenSource: (String) -> Void
    private let logLevel: AppSynkOptions.LogLevel

    init(
        network: NetworkService,
        attributionStore: AttributionService,
        track: @escaping TrackHandler,
        markOpenSource: @escaping (String) -> Void,
        logLevel: AppSynkOptions.LogLevel
    ) {
        self.network = network
        self.attributionStore = attributionStore
        self.track = track
        self.markOpenSource = markOpenSource
        self.logLevel = logLevel
        // Seed with the last resolved deep link so a cold-start callback replays it (deferred deep link).
        self.buffer = DeepLinkBuffer(seed: Self.loadPersisted())
    }

    // MARK: - Entry points

    /// Call from `application(_:open:options:)`. Handles `appsynk://…` and `go.appsynk.io` URLs.
    func handleOpenURL(_ url: URL) {
        guard let linkId = Self.linkId(from: url) else { return }
        Task { await resolve(linkId: linkId) }
    }

    /// Call from `application(_:continue:restorationHandler:)` for `https://go.appsynk.io/{linkId}`.
    func handleUniversalLink(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              url.host == Self.universalHost,
              let linkId = Self.linkId(from: url) else { return }
        Task { await resolve(linkId: linkId) }
    }

    /// Re-engagement: explicitly report a deep-link re-open (LinkRunner doctrine).
    func handleDeeplink(url: URL) {
        handleOpenURL(url)
    }

    // MARK: - Callbacks

    /// Deep-link attribution, replayed if it resolved before this call (fires on the main thread).
    func getDeepLinkData(_ callback: @escaping (AttributionData?) -> Void) {
        buffer.register(callback)
    }

    /// Best-known attribution (deep link if any, else organic). Always fires, on the main thread.
    func getAttributionData(_ callback: @escaping (AttributionData?) -> Void) {
        buffer.current { resolved in callback(resolved ?? .organic) }
    }

    // MARK: - Resolution

    private func resolve(linkId: String) async {
        do {
            let attribution = try await network.resolveLinkAttribution(linkId: linkId)
            attributionStore.storeAttribution(attribution)   // channel/clickId for event enrichment
            Self.persist(attribution)
            buffer.deliver(attribution)                        // replay to buffered callbacks
            markOpenSource("deeplink")                         // attribute the next app_open to the link

            // Re-engagement: record the deep-link open in the events pipeline.
            await track("deeplink", [
                "link_id":   linkId,
                "channel":   attribution.channel ?? "unknown",
                "campaign":  attribution.campaignName ?? "",
                "deep_link": attribution.deepLink ?? ""
            ])
            log("Deep link resolved: \(linkId) channel=\(attribution.channel ?? "?")")
        } catch {
            log("Deep link resolution failed for \(linkId): \(error.localizedDescription)")
        }
    }

    // MARK: - URL parsing

    /// Extracts the tracking linkId from an `appsynk://` custom scheme or a `go.appsynk.io` link.
    static func linkId(from url: URL) -> String? {
        guard url.host == universalHost || url.scheme == customScheme else { return nil }
        let linkId = url.lastPathComponent
        guard !linkId.isEmpty, linkId != "/" else { return nil }
        return linkId
    }

    // MARK: - Persistence

    private static func loadPersisted() -> AttributionData? {
        guard let data = UserDefaults.standard.data(forKey: persistKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AttributionData.self, from: data)
    }

    private static func persist(_ attribution: AttributionData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(attribution) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func log(_ message: String) {
        if logLevel != .none { print("[AppSynk] \(message)") }
    }
}
