import Foundation

/// Stores the attribution **result** (deep-link / install attribution) and exposes the click id
/// for event enrichment.
///
/// Device-derived identifiers (IDFA / IDFV / SKAdNetwork version) moved to `DeviceDataCollector`,
/// which now owns the whole attribution wire block. This service is purely the persisted store for
/// the resolved attribution and will fold into `DeepLinkResolver` in a later module.
///
/// Thread-safe: `_cachedAttribution` is written from the deep-link resolver's Task and read from the
/// event-building Task, so every access is serialized through an `NSLock` (same pattern as
/// `PrivacyManager`).
public final class AttributionService {
    private static let attributionKey = "appsynk_attribution"

    private let lock = NSLock()
    private var _cachedAttribution: AttributionData?

    public init() {
        _cachedAttribution = Self.loadStoredAttribution()
    }

    /// Click id from the stored attribution result, overlaid onto each event's attribution block.
    public var clickId: String? {
        lock.lock(); defer { lock.unlock() }
        return _cachedAttribution?.clickId
    }

    /// Persist the attribution result received from the API after an install / deep link is attributed.
    public func storeAttribution(_ attribution: AttributionData) {
        lock.lock(); _cachedAttribution = attribution; lock.unlock()
        if let data = try? JSONEncoder().encode(attribution) {
            UserDefaults.standard.set(data, forKey: Self.attributionKey)
        }
    }

    /// The stored attribution result, if any.
    public func getAttributionData() -> AttributionData? {
        lock.lock(); defer { lock.unlock() }
        return _cachedAttribution
    }

    /// Clear all stored attribution data (called on `reset()`).
    public static func clearStoredAttribution() {
        UserDefaults.standard.removeObject(forKey: attributionKey)
    }

    // MARK: - Private

    private static func loadStoredAttribution() -> AttributionData? {
        guard let data = UserDefaults.standard.data(forKey: attributionKey) else { return nil }
        return try? JSONDecoder().decode(AttributionData.self, from: data)
    }
}
