import Foundation

/// Stable per-install device identifier — the "install instance id".
///
/// Persisted in `UserDefaults`, deliberately **not** the Keychain. The Keychain can survive an
/// uninstall and even restore across devices via iCloud Keychain; if the id were restored, two
/// distinct installs would share one id and corrupt attribution. We want an id that is stable
/// for the life of one install and gone on uninstall. (Telling install from reinstall is a
/// separate concern handled later, via the Keychain.)
public enum DeviceIdentity {

    /// UserDefaults key holding the install instance id.
    static let storageKey = "appsynk_device_id"

    /// Serializes get-or-create so concurrent first accesses can't generate two different ids.
    private static let lock = NSLock()

    /// The stable install instance id, generated and persisted on first access.
    ///
    /// Thread-safe: the first concurrent callers all observe the same id. Returns the same value
    /// on every subsequent launch until the app is uninstalled.
    /// - Parameter defaults: storage to use; overridable in tests.
    public static func installInstanceId(defaults: UserDefaults = .standard) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: storageKey)
        return newId
    }
}
