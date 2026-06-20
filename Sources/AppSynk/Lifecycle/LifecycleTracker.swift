import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Emits the automatic lifecycle events — install / reinstall / session_start / session_end /
/// app_open / app_update — and owns session state + the foreground/background observers.
///
/// Events are enqueued through the facade (injected `track`); install is gated on the ATT decision
/// (Prompt 6) and carries the AdServices token (Prompt 7). This is what makes AppSynk richer than
/// LinkRunner's single init.
final class LifecycleTracker {
    typealias TrackHandler = (_ name: String, _ properties: [String: Any], _ adServicesToken: String?) async -> Void
    typealias TokenHandler = (_ token: String) async -> Void

    enum InstallState { case firstInstall, reinstall, existing }

    private let options: AppSynkOptions
    private let track: TrackHandler
    private let postAdServicesToken: TokenHandler

    // Persistence keys.
    private static let installTrackedKey = "appsynk_install_tracked"
    private static let installDateKey     = "appsynk_install_date"
    private static let appVersionKey      = "appsynk_app_version"
    private static let adOpenSentKey      = "appsynk_adservices_open_sent"
    private static let keychainSeen       = "appsynk_seen"

    // Session state — accessed only through stateQueue.
    private let stateQueue = DispatchQueue(label: "io.appsynk.lifecycle")
    private var sessionId = UUID().uuidString
    private var sessionStartTime = Date()
    private var sessionNumber = 0
    private var backgroundedAt: Date?
    private var didStartFirstSession = false
    private var pendingOpenSource: String?

    init(options: AppSynkOptions, track: @escaping TrackHandler, postAdServicesToken: @escaping TokenHandler) {
        self.options = options
        self.track = track
        self.postAdServicesToken = postAdServicesToken
    }

    // MARK: - Facade surface

    /// Current session id (thread-safe). The facade folds it into every event's properties.
    var currentSessionId: String { stateQueue.sync { sessionId } }

    /// Source attributed to the NEXT app_open (e.g. "deeplink"); defaults to "direct".
    func markOpenSource(_ source: String) { stateQueue.async { self.pendingOpenSource = source } }

    /// Rotate the session (called from reset()).
    func resetSession() {
        stateQueue.async {
            self.sessionId = UUID().uuidString
            self.sessionStartTime = Date()
        }
    }

    /// Registers observers and runs the launch sequence. Call once from the main thread (configure).
    func start() {
        registerObservers()
        Task { await self.trackLaunch() }
    }

    // MARK: - Launch: install / reinstall / app_update

    private func trackLaunch() async {
        await trackInstallIfNeeded()
        await trackAppUpdateIfNeeded()
    }

    private func trackInstallIfNeeded() async {
        let state = Self.resolveInstallState(
            udTracked: UserDefaults.standard.bool(forKey: Self.installTrackedKey),
            keychainSeen: Keychain.flagExists(Self.keychainSeen)
        )
        guard state != .existing else { return }

        // SKAdNetwork registration on first launch (unless disabled) — independent of ATT.
        if !options.disableSKAdNetwork {
            SKAdNetworkManager.shared.register()
        }

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.installDateKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.installDateKey)
        }

        // AppsFlyer-style ATT gating before sending the install/reinstall.
        await ATTManager.waitForAuthorization(timeout: options.attWaitTimeout)

        let token = options.disableAdServices ? nil : AdServicesTokenProvider.token()
        let name = (state == .reinstall) ? "reinstall" : "install"
        await track(name, [
            "referrer":   installReferrer() ?? "direct",
            "version":    Self.appVersion(),
            "att_status": ATTManager.statusString
        ], token)

        if let token { await postAdServicesToken(token) }

        // Persist (UserDefaults flag + Keychain "seen") ONLY after the event is enqueued, so a kill
        // during the ATT wait re-attempts on the next launch instead of losing the install.
        defaults.set(true, forKey: Self.installTrackedKey)
        Keychain.setFlag(Self.keychainSeen)
    }

    private func trackAppUpdateIfNeeded() async {
        let defaults = UserDefaults.standard
        let current = Self.appVersion()
        if let stored = defaults.string(forKey: Self.appVersionKey), stored != current {
            await track("app_update", ["previous_version": stored, "new_version": current], nil)
        }
        defaults.set(current, forKey: Self.appVersionKey)
    }

    /// Read-only state resolution (testable). Writes nothing — the flags are set in
    /// `trackInstallIfNeeded` only after the event is enqueued, so an interrupted install retries.
    static func resolveInstallState(udTracked: Bool, keychainSeen: Bool) -> InstallState {
        if udTracked { return .existing }
        return keychainSeen ? .reinstall : .firstInstall
    }

    // MARK: - Foreground / background

    private func registerObservers() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleColdLaunchActivation()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleReturnToForeground()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleBackground()
        }
        #endif
    }

    /// Cold launch: only the FIRST activation starts session 1. Subsequent returns are handled by
    /// willEnterForeground; a spurious didBecomeActive (e.g. Control Center) is ignored here.
    private func handleColdLaunchActivation() {
        stateQueue.async {
            guard !self.didStartFirstSession else { return }
            self.didStartFirstSession = true
            self.beginSessionLocked()
            self.emitAppOpenLocked()
            self.sendAdServicesTokenOnFirstOpen()
        }
    }

    /// Returning from background: start a new session if inactivity exceeded sessionTimeout.
    private func handleReturnToForeground() {
        stateQueue.async {
            guard self.didStartFirstSession else { return } // cold launch is handled above
            let inactivity = self.backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.backgroundedAt = nil
            if Self.shouldStartNewSession(inactivity: inactivity, timeout: self.options.sessionTimeout) {
                self.beginSessionLocked()
            }
            self.emitAppOpenLocked()
            self.sendAdServicesTokenOnFirstOpen()
        }
    }

    private func handleBackground() {
        stateQueue.async {
            self.backgroundedAt = Date()
            let duration = Int(Date().timeIntervalSince(self.sessionStartTime))
            self.emit("session_end", ["session_duration_seconds": duration])
        }
    }

    static func shouldStartNewSession(inactivity: TimeInterval, timeout: TimeInterval) -> Bool {
        inactivity > timeout
    }

    // MARK: - Session helpers (run on stateQueue)

    private func beginSessionLocked() {
        sessionId = UUID().uuidString
        sessionStartTime = Date()
        sessionNumber += 1
        var props: [String: Any] = ["session_id": sessionId]
        if let installDate = UserDefaults.standard.object(forKey: Self.installDateKey) as? TimeInterval {
            let timeSinceInstall = Date().timeIntervalSince1970 - installDate
            props["time_since_install"] = Int(timeSinceInstall)
            props["day_since_install"] = Int(timeSinceInstall / 86_400)
        }
        emit("session_start", props)
    }

    private func emitAppOpenLocked() {
        let source = pendingOpenSource ?? "direct"
        pendingOpenSource = nil
        emit("app_open", ["source": source, "session_number": sessionNumber])
    }

    private func emit(_ name: String, _ properties: [String: Any]) {
        Task { await self.track(name, properties, nil) }
    }

    /// Second AdServices token send on the first app_open after install (a fresh, still-valid token).
    /// Fires once per install; never on the install launch itself (install flag not yet set then).
    private func sendAdServicesTokenOnFirstOpen() {
        guard !options.disableAdServices else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.installTrackedKey),
              !defaults.bool(forKey: Self.adOpenSentKey),
              let token = AdServicesTokenProvider.token() else { return }
        defaults.set(true, forKey: Self.adOpenSentKey)
        Task { await self.postAdServicesToken(token) }
    }

    // MARK: - Misc

    private func installReferrer() -> String? {
        UserDefaults.standard.string(forKey: "appsynk_referrer")
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
