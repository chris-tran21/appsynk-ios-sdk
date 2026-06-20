import XCTest
@testable import AppSynk

/// SKAdNetwork pure-logic tests (Prompt 8): coarse mapping + the monotonic guard. The actual
/// version-gated dispatch and register-once hit the system SKAdNetwork class, so they are verified
/// on a real simulator/device (iOS 15 vs 16.1+) rather than in unit tests.
final class SKAdNetworkTests: XCTestCase {

    func testCoarseNameForTier() {
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 0), "low")
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 2), "low")
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 3), "medium")
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 5), "medium")
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 6), "high")
        XCTAssertEqual(SKAdNetworkManager.coarseName(forTier: 7), "high")
    }

    func testIsValidCoarse() {
        XCTAssertTrue(SKAdNetworkManager.isValidCoarse("low"))
        XCTAssertTrue(SKAdNetworkManager.isValidCoarse("Medium"))
        XCTAssertTrue(SKAdNetworkManager.isValidCoarse("HIGH"))
        XCTAssertFalse(SKAdNetworkManager.isValidCoarse("ultra"))
        XCTAssertFalse(SKAdNetworkManager.isValidCoarse(""))
    }

    // MARK: - Monotonic guard

    func testAppliesWhenNeverUpdated() {
        XCTAssertTrue(SKAdNetworkManager.shouldApply(
            fine: 5, coarse: "low", lockWindow: false,
            lastFine: nil, lastCoarse: nil, lastLock: nil))
    }

    func testIgnoresLowerFine() {
        XCTAssertFalse(SKAdNetworkManager.shouldApply(
            fine: 3, coarse: "low", lockWindow: false,
            lastFine: 5, lastCoarse: "low", lastLock: false))
    }

    func testAppliesHigherFine() {
        XCTAssertTrue(SKAdNetworkManager.shouldApply(
            fine: 7, coarse: "high", lockWindow: false,
            lastFine: 5, lastCoarse: "medium", lastLock: false))
    }

    func testIgnoresIdenticalUpdate() {
        XCTAssertFalse(SKAdNetworkManager.shouldApply(
            fine: 5, coarse: "low", lockWindow: false,
            lastFine: 5, lastCoarse: "low", lastLock: false))
    }

    func testAppliesSameFineDifferentCoarse() {
        XCTAssertTrue(SKAdNetworkManager.shouldApply(
            fine: 5, coarse: "medium", lockWindow: false,
            lastFine: 5, lastCoarse: "low", lastLock: false))
    }

    func testAppliesSameFineDifferentLock() {
        XCTAssertTrue(SKAdNetworkManager.shouldApply(
            fine: 5, coarse: "low", lockWindow: true,
            lastFine: 5, lastCoarse: "low", lastLock: false))
    }

    // MARK: - disableSKAdNetwork gating (collector)

    @MainActor
    func testCollectorOmitsSkanFieldsWhenDisabled() {
        var options = AppSynkOptions()
        options.disableSKAdNetwork = true
        let data = DeviceDataCollector().collect(options: options)
        XCTAssertNil(data.attribution.skanConversionValueApplied)
        XCTAssertNil(data.attribution.skAdNetworkVersion)
    }
}
