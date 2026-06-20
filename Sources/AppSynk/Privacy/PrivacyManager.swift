import Foundation

/// GDPR consent + anonymization state. Persisted and thread-safe — read by `buildEvent` on every
/// event, so it must be safe to read from any thread.
final class PrivacyManager {
    private static let consentKey    = "appsynk:consent"
    private static let anonymizedKey = "appsynk:anonymized"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _consent: ConsentPayload?
    private var _anonymized: Bool

    init(anonymizeByDefault: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Restore the persisted anonymized flag, falling back to the configured default.
        if let stored = defaults.object(forKey: Self.anonymizedKey) as? Bool {
            self._anonymized = stored
        } else {
            self._anonymized = anonymizeByDefault
        }
        self._consent = Self.loadConsent(from: defaults)
    }

    // MARK: - Read (thread-safe)

    var consent: ConsentPayload? {
        lock.lock(); defer { lock.unlock() }
        return _consent
    }

    var isAnonymized: Bool {
        lock.lock(); defer { lock.unlock() }
        return _anonymized
    }

    // MARK: - Write

    func setConsent(
        isUserSubjectToGDPR: Bool,
        hasConsentForDataUsage: Bool,
        hasConsentForAdsPersonalization: Bool
    ) {
        let payload = ConsentPayload(
            isUserSubjectToGDPR: isUserSubjectToGDPR,
            hasConsentForDataUsage: hasConsentForDataUsage,
            hasConsentForAdsPersonalization: hasConsentForAdsPersonalization,
            consentTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        lock.lock(); _consent = payload; lock.unlock()
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.consentKey)
        }
    }

    func setAnonymized(_ enabled: Bool) {
        lock.lock(); _anonymized = enabled; lock.unlock()
        defaults.set(enabled, forKey: Self.anonymizedKey)
    }

    // MARK: - Persistence

    private static func loadConsent(from defaults: UserDefaults) -> ConsentPayload? {
        guard let data = defaults.data(forKey: consentKey) else { return nil }
        return try? JSONDecoder().decode(ConsentPayload.self, from: data)
    }
}
