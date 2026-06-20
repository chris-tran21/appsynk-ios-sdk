import Foundation
import AppTrackingTransparency
import AdSupport

/// App Tracking Transparency: read the status, request the prompt (dev-initiated only), and wait
/// for the user's decision with a timeout (AppsFlyer-style install gating).
///
/// The SDK NEVER shows the ATT prompt on its own — the developer calls
/// `requestTrackingAuthorization` at the right moment (after onboarding). The SDK only *waits* for
/// the resolution so the install event can carry the IDFA when the user grants it.
public enum ATTManager {

    /// Current ATT status, without prompting.
    public static var status: ATTrackingManager.AuthorizationStatus {
        ATTrackingManager.trackingAuthorizationStatus
    }

    /// Human-readable status: "authorized" | "denied" | "restricted" | "not_determined".
    static var statusString: String {
        switch status {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default:    return "not_determined"
        }
    }

    /// The IDFA — only when ATT is authorized and the value is non-zero; nil otherwise.
    public static var idfa: String? {
        guard status == .authorized else { return nil }
        let value = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return value == "00000000-0000-0000-0000-000000000000" ? nil : value
    }

    /// True only when tracking is authorized.
    public static var isTrackingAuthorized: Bool { status == .authorized }

    /// Requests the ATT prompt, presented on the main thread. The developer calls this — the SDK
    /// never triggers it implicitly.
    public static func requestTrackingAuthorization(
        completion: @escaping (ATTrackingManager.AuthorizationStatus) -> Void
    ) {
        DispatchQueue.main.async {
            ATTrackingManager.requestTrackingAuthorization { completion($0) }
        }
    }

    /// Waits until the user leaves `.notDetermined` (responds to the prompt) OR the timeout elapses,
    /// whichever comes first. Returns immediately if already decided. Polls every 200 ms and never
    /// shows the prompt itself.
    static func waitForAuthorization(timeout: TimeInterval) async {
        await waitUntilDecided(timeout: timeout, pollInterval: 0.2) { status }
    }

    /// Testable core of `waitForAuthorization`: polls `statusProvider` until it leaves
    /// `.notDetermined` or the deadline passes.
    static func waitUntilDecided(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        statusProvider: () -> ATTrackingManager.AuthorizationStatus
    ) async {
        guard statusProvider() == .notDetermined else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while statusProvider() == .notDetermined && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}
