import XCTest
@testable import AppSynk

/// Consent + anonymization (Prompt 11): the PrivacyManager state/persistence and the attribution
/// anonymization. The per-event wiring (consent attached, identifiers stripped) is exercised here at
/// the unit level; the full sdk/init validation logging is verified against the live API.
final class PrivacyTests: XCTestCase {

    private func freshDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "io.appsynk.privacy.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - Consent

    func testSetConsentCapturesAllThreeFlagsAndTimestamp() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let privacy = PrivacyManager(anonymizeByDefault: false, defaults: defaults)
        privacy.setConsent(isUserSubjectToGDPR: true, hasConsentForDataUsage: true, hasConsentForAdsPersonalization: false)

        let consent = privacy.consent
        XCTAssertEqual(consent?.isUserSubjectToGDPR, true)
        XCTAssertEqual(consent?.hasConsentForDataUsage, true)
        XCTAssertEqual(consent?.hasConsentForAdsPersonalization, false)
        XCTAssertNotNil(consent?.consentTimestamp)
    }

    func testConsentPersistsAcrossInstances() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        PrivacyManager(anonymizeByDefault: false, defaults: defaults)
            .setConsent(isUserSubjectToGDPR: false, hasConsentForDataUsage: true, hasConsentForAdsPersonalization: true)

        let reloaded = PrivacyManager(anonymizeByDefault: false, defaults: defaults)
        XCTAssertEqual(reloaded.consent?.hasConsentForDataUsage, true)
        XCTAssertEqual(reloaded.consent?.hasConsentForAdsPersonalization, true)
        XCTAssertEqual(reloaded.consent?.isUserSubjectToGDPR, false)
    }

    // MARK: - Anonymization

    func testAnonymizeUserTogglesAndPersists() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let privacy = PrivacyManager(anonymizeByDefault: false, defaults: defaults)
        XCTAssertFalse(privacy.isAnonymized)
        privacy.setAnonymized(true)
        XCTAssertTrue(privacy.isAnonymized)

        // Survives a relaunch (new instance, same store).
        XCTAssertTrue(PrivacyManager(anonymizeByDefault: false, defaults: defaults).isAnonymized)
    }

    func testAnonymizeByDefaultAppliesFromStart() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PrivacyManager(anonymizeByDefault: true, defaults: defaults).isAnonymized)
    }

    func testAnonymizedCopyStripsIdentifiersOnly() {
        var attribution = AttributionInfo(idfv: "IDFV", skAdNetworkVersion: "4.0")
        attribution.idfa = "IDFA"
        attribution.adServicesToken = "TOKEN"
        attribution.skanConversionValueApplied = 42

        let anon = attribution.anonymizedCopy()

        XCTAssertNil(anon.idfa)
        XCTAssertNil(anon.idfv)
        XCTAssertNil(anon.adServicesToken)
        XCTAssertTrue(anon.isAnonymized)
        // Non-identifying signals are preserved.
        XCTAssertEqual(anon.skAdNetworkVersion, "4.0")
        XCTAssertEqual(anon.skanConversionValueApplied, 42)
    }
}
