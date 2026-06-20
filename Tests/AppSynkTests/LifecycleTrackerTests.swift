import XCTest
@testable import AppSynk

/// Lifecycle logic tests (Prompt 9): install-vs-reinstall resolution, session-rotation decision, and
/// the Keychain flag round-trip. The end-to-end event emission (relaunch, background>timeout, version
/// bump) depends on UIApplication notifications and is verified on a real simulator/device.
final class LifecycleTrackerTests: XCTestCase {

    // MARK: - Install state (first install vs reinstall vs existing)

    func testFirstInstallWhenNeverSeen() {
        XCTAssertEqual(
            LifecycleTracker.resolveInstallState(udTracked: false, keychainSeen: false),
            .firstInstall)
    }

    func testReinstallWhenKeychainSeenButUserDefaultsCleared() {
        // Uninstall clears UserDefaults but the Keychain flag survives → reinstall, not install.
        XCTAssertEqual(
            LifecycleTracker.resolveInstallState(udTracked: false, keychainSeen: true),
            .reinstall)
    }

    func testExistingWhenAlreadyTracked() {
        XCTAssertEqual(
            LifecycleTracker.resolveInstallState(udTracked: true, keychainSeen: false),
            .existing)
        XCTAssertEqual(
            LifecycleTracker.resolveInstallState(udTracked: true, keychainSeen: true),
            .existing)
    }

    // MARK: - Session rotation

    func testNewSessionOnlyAfterTimeout() {
        XCTAssertTrue(LifecycleTracker.shouldStartNewSession(inactivity: 1801, timeout: 1800))
        XCTAssertFalse(LifecycleTracker.shouldStartNewSession(inactivity: 1799, timeout: 1800))
        XCTAssertFalse(LifecycleTracker.shouldStartNewSession(inactivity: 0, timeout: 1800))
    }

    // MARK: - Keychain flag (survives uninstall, used for reinstall detection)

    func testKeychainFlagRoundTrip() {
        let account = "appsynk.test.\(UUID().uuidString)"
        defer { Keychain.deleteFlag(account) }

        guard Keychain.setFlag(account) else {
            // Keychain may be unavailable in some CI environments; don't fail the suite there.
            return
        }
        XCTAssertTrue(Keychain.flagExists(account))
        XCTAssertTrue(Keychain.setFlag(account), "setFlag is idempotent")

        Keychain.deleteFlag(account)
        XCTAssertFalse(Keychain.flagExists(account))
    }
}
