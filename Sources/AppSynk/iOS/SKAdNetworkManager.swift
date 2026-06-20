import Foundation
import StoreKit

/// Internal SKAdNetwork errors (logged, never surfaced to the developer).
enum SkanError: Error {
    case osUnsupported
    case frameworkMissing
    case apiUnavailable
    case invalidCoarse
}

/// Production-grade SKAdNetwork manager, modelled on Adjust's `ADJSKAdNetwork`:
/// fine iOS version gating (16.1 / 15.4 / 14.0), framework + method availability checks, a monotonic
/// guard (never lower the fine value; skip identical updates), register-once, and server-piloted
/// values. The developer only ever controls `disableSKAdNetwork` (the facade gates every call).
///
/// Dynamic-dispatch note: Adjust (Objective-C) uses `NSInvocation` + `dlsym` to avoid a hard symbol
/// dependency. `NSInvocation` is unavailable in Swift, so we call the typed `SKAdNetwork` API under
/// `#available` (StoreKit is always present on iOS 14+) while keeping the doctrine's safety checks —
/// `NSClassFromString` for the framework and `responds(to:)` for the method.
final class SKAdNetworkManager {
    static let shared = SKAdNetworkManager()

    private let queue = DispatchQueue(label: "io.appsynk.skan", qos: .utility)
    private let defaults = UserDefaults.standard

    private let registerKey   = "appsynk_skan_register_ts"
    private let lastFineKey    = "appsynk_skan_last_fine"
    private let lastCoarseKey  = "appsynk_skan_last_coarse"
    private let lastLockKey    = "appsynk_skan_last_lock"
    private let lastSourceKey  = "appsynk_skan_last_source"
    private let lastUpdateKey  = "appsynk_skan_last_update_ts"

    private init() {}

    /// Last applied conversion value (fine), or nil if SKAdNetwork has never been updated.
    static var appliedConversionValue: Int? {
        UserDefaults.standard.object(forKey: "appsynk_skan_last_fine") as? Int
    }

    // MARK: - Register (once)

    /// First-install registration: initial value 0 / coarse "low" / no lock. Idempotent — a
    /// persisted timestamp prevents double registration.
    func register() {
        queue.async { [self] in
            guard defaults.object(forKey: registerKey) == nil else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: registerKey)
            applyUpdate(fine: 0, coarse: "low", lockWindow: false, source: "sdk")
        }
    }

    // MARK: - Update

    /// Update the conversion value. `source` ∈ {"sdk","backend","client"}. Runs on the serial queue.
    func updateConversionValue(fine: Int, coarse: String?, lockWindow: Bool, source: String) {
        queue.async { [self] in
            applyUpdate(fine: fine, coarse: coarse, lockWindow: lockWindow, source: source)
        }
    }

    // MARK: - Core (serial queue)

    private func applyUpdate(fine: Int, coarse: String?, lockWindow: Bool, source: String) {
        guard checkFrameworkAvailability() else {
            log("framework unavailable — skipped"); return
        }

        // Resolve coarse: explicit (validated) or derived from the revenue tier (fine >> 3).
        let resolvedCoarse: String
        if let coarse {
            guard Self.isValidCoarse(coarse) else {
                log("invalid coarse '\(coarse)' — rejected (no SKAN call)"); return
            }
            resolvedCoarse = coarse.lowercased()
        } else {
            resolvedCoarse = Self.coarseName(forTier: fine >> 3)
        }

        // Monotonic guard.
        let lastFine = defaults.object(forKey: lastFineKey) as? Int
        guard Self.shouldApply(
            fine: fine, coarse: resolvedCoarse, lockWindow: lockWindow,
            lastFine: lastFine,
            lastCoarse: defaults.string(forKey: lastCoarseKey),
            lastLock: defaults.object(forKey: lastLockKey) as? Bool
        ) else {
            log("ignored (monotonic guard): fine=\(fine) last=\(lastFine.map(String.init) ?? "nil")"); return
        }

        dispatchUpdate(fine: fine, coarse: resolvedCoarse, lockWindow: lockWindow)

        // Persist lastSkanUpdateData { fine, coarse, lock, source, timestamp }.
        defaults.set(fine, forKey: lastFineKey)
        defaults.set(resolvedCoarse, forKey: lastCoarseKey)
        defaults.set(lockWindow, forKey: lastLockKey)
        defaults.set(source, forKey: lastSourceKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastUpdateKey)
        log("updated: fine=\(fine) coarse=\(resolvedCoarse) lock=\(lockWindow) source=\(source)")
    }

    /// iOS-version-gated dispatch to the typed SKAdNetwork API. `#available` guarantees the method
    /// exists; the framework presence is checked separately (doctrine).
    private func dispatchUpdate(fine: Int, coarse: String, lockWindow: Bool) {
        if #available(iOS 16.1, *) {
            guard let coarseValue = Self.coarseValue(for: coarse) else { return } // invalidCoarse
            checkMethodAvailability("updatePostbackConversionValue:coarseValue:lockWindow:completionHandler:")
            SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: coarseValue, lockWindow: lockWindow) { [self] error in
                if let error { log("16.1 update error: \(error.localizedDescription)") }
            }
        } else if #available(iOS 15.4, *) {
            checkMethodAvailability("updatePostbackConversionValue:completionHandler:")
            SKAdNetwork.updatePostbackConversionValue(fine) { [self] error in
                if let error { log("15.4 update error: \(error.localizedDescription)") }
            }
        } else {
            // iOS 14.0–15.3: the only conversion-value API here (updateConversionValue:) is
            // deprecated, so conversion values are skipped below iOS 15.4 — Apple still attributes
            // the install, there is simply no fine/coarse update. Keeps the build warning-free.
            log("conversion value skipped — requires iOS 15.4+")
        }
    }

    // MARK: - Availability checks (doctrine)

    /// Framework present, not tvOS, iOS 14+. NSClassFromString keeps this a soft dependency.
    private func checkFrameworkAvailability() -> Bool {
        #if os(tvOS)
        return false
        #else
        if #available(iOS 14.0, *) {
            return NSClassFromString("SKAdNetwork") != nil
        }
        return false
        #endif
    }

    /// Diagnostic only: the typed call above is `#available`-guaranteed, so a false here just logs
    /// (it never silently disables SKAN over a selector-string mismatch).
    @discardableResult
    private func checkMethodAvailability(_ selectorName: String) -> Bool {
        guard let cls = NSClassFromString("SKAdNetwork") as? NSObject.Type else { return false }
        let available = cls.responds(to: NSSelectorFromString(selectorName))
        if !available { log("method \(selectorName) not reported by responds(to:)") }
        return available
    }

    // MARK: - Coarse mapping

    static func isValidCoarse(_ value: String) -> Bool {
        ["low", "medium", "high"].contains(value.lowercased())
    }

    /// Derive the coarse bucket from the 0–7 revenue tier (upper 3 bits of the fine value).
    static func coarseName(forTier tier: Int) -> String {
        switch tier {
        case ..<3:  return "low"
        case 3...5: return "medium"
        default:    return "high"
        }
    }

    /// Pure monotonic-guard decision (testable): apply unless the fine value would drop or the update
    /// is strictly identical (same fine + coarse + lock).
    static func shouldApply(
        fine: Int, coarse: String, lockWindow: Bool,
        lastFine: Int?, lastCoarse: String?, lastLock: Bool?
    ) -> Bool {
        guard let lastFine else { return true }
        if fine < lastFine { return false }
        if fine == lastFine, coarse == lastCoarse, lockWindow == lastLock { return false }
        return true
    }

    @available(iOS 16.1, *)
    private static func coarseValue(for name: String) -> SKAdNetwork.CoarseConversionValue? {
        switch name.lowercased() {
        case "low":    return .low
        case "medium": return .medium
        case "high":   return .high
        default:       return nil
        }
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[AppSynk][SKAN] \(message)")
        #endif
    }
}
