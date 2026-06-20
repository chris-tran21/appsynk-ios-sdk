import XCTest
import AppTrackingTransparency
@testable import AppSynk

/// Tests the ATT wait/timeout logic that gates the install (Prompt 6). The real
/// `ATTrackingManager` status is system-controlled, so we exercise the testable core
/// `waitUntilDecided` with an injected status provider. (IDFA presence / prompt-never-shown are
/// device-level behaviours verified manually.)
final class ATTGatingTests: XCTestCase {

    /// Sequential, single-consumer counter for the status provider (no concurrent access).
    private final class Counter {
        private var n = 0
        func next() -> Int { n += 1; return n }
        var value: Int { n }
    }

    func testReturnsImmediatelyWhenAlreadyDecided() async {
        let start = Date()
        await ATTManager.waitUntilDecided(timeout: 5.0, pollInterval: 0.05) { .authorized }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "must not wait when already decided")
    }

    func testReturnsAfterTimeoutWhenNeverDecided() async {
        let start = Date()
        await ATTManager.waitUntilDecided(timeout: 0.4, pollInterval: 0.05) { .notDetermined }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.35, "must wait roughly the full timeout")
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testReturnsEarlyWhenStatusLeavesNotDetermined() async {
        let counter = Counter()
        let start = Date()
        // notDetermined for the first two polls, then authorized.
        await ATTManager.waitUntilDecided(timeout: 5.0, pollInterval: 0.05) {
            counter.next() >= 3 ? .authorized : .notDetermined
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "must return as soon as the user decides, not wait the timeout")
        XCTAssertGreaterThanOrEqual(counter.value, 3)
    }
}
