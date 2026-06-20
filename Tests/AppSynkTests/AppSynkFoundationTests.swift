import XCTest
@testable import AppSynk

/// Foundation-level tests (Prompt 1): device identity stability + options/constants wiring.
/// Foundation-only — no UIKit — so they compile and run on the iOS test host.
final class AppSynkFoundationTests: XCTestCase {

    private func freshDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "io.appsynk.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - DeviceIdentity

    func testInstallInstanceIdIsStableAcrossCalls() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceIdentity.installInstanceId(defaults: defaults)
        let second = DeviceIdentity.installInstanceId(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "The install instance id must be stable across calls.")
    }

    func testInstallInstanceIdSurvivesReload() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let generated = DeviceIdentity.installInstanceId(defaults: defaults)
        // A fresh handle on the same suite simulates a relaunch reading persisted storage.
        let reloaded = UserDefaults(suiteName: suite)!.string(forKey: DeviceIdentity.storageKey)

        XCTAssertEqual(generated, reloaded, "The install instance id must persist across launches.")
    }

    // MARK: - AppSynkOptions

    func testOptionsExposeAllDefaults() {
        let opts = AppSynkOptions()

        XCTAssertEqual(opts.sessionTimeout, 1800)
        XCTAssertEqual(opts.batchSize, 10)
        XCTAssertEqual(opts.flushInterval, 30)
        XCTAssertEqual(opts.attWaitTimeout, 60)
        XCTAssertTrue(opts.sendInBackground)

        XCTAssertFalse(opts.disableIdfa)
        XCTAssertFalse(opts.disableIdfv)
        XCTAssertFalse(opts.disableAdServices)
        XCTAssertFalse(opts.disableSKAdNetwork)
        XCTAssertFalse(opts.anonymizeUserByDefault)

        XCTAssertNil(opts.customApiUrl)
        XCTAssertNil(opts.hmacSecretKey)
        XCTAssertNil(opts.hmacKeyId)
    }

    // MARK: - Constants as single source of truth

    func testConstantsAreSingleSourceOfTruth() {
        XCTAssertEqual(AppSynkConstants.platform, "ios")
        XCTAssertFalse(AppSynkConstants.sdkVersion.isEmpty)
        XCTAssertEqual(AppSynkOptions.Environment.production.baseUrl, AppSynkConstants.productionBaseURL)
        XCTAssertEqual(AppSynkOptions.Environment.sandbox.baseUrl, AppSynkConstants.sandboxBaseURL)
    }

    // MARK: - trackRevenue dedup index

    func testRevenueDedupIgnoresDuplicateWithinWindow() {
        let now: TimeInterval = 1_000_000
        var result = AppSynkSDK.dedupOrder("order-1", now: now, index: [:])
        XCTAssertFalse(result.isDuplicate)
        XCTAssertNotNil(result.updatedIndex["order-1"])

        result = AppSynkSDK.dedupOrder("order-1", now: now + 3_600, index: result.updatedIndex)
        XCTAssertTrue(result.isDuplicate, "same orderId within 24h must be a duplicate")
    }

    func testRevenueDedupPurgesEntriesOlderThan24h() {
        let now: TimeInterval = 1_000_000
        let stale = ["order-old": now - 90_000]   // older than the 86_400s window
        let result = AppSynkSDK.dedupOrder("order-old", now: now, index: stale)
        XCTAssertFalse(result.isDuplicate, "an expired entry is not a duplicate")
        XCTAssertEqual(result.updatedIndex.count, 1, "stale entries are purged — no unbounded growth")
    }

    func testRevenueDedupAllowsDistinctOrders() {
        let now: TimeInterval = 1_000_000
        let first = AppSynkSDK.dedupOrder("a", now: now, index: [:])
        let second = AppSynkSDK.dedupOrder("b", now: now, index: first.updatedIndex)
        XCTAssertFalse(second.isDuplicate)
        XCTAssertEqual(second.updatedIndex.count, 2)
    }
}
