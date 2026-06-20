import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreTelephony)
import CoreTelephony
#endif
#if canImport(Network)
import Network
#endif

// MARK: - NetworkTypeMonitor

/// A single `NWPathMonitor`, started once, exposing the current connectivity type thread-safely.
/// One monitor per process (shared) — creating one per call leaks resources and races.
final class NetworkTypeMonitor {
    static let shared = NetworkTypeMonitor()

    private let queue = DispatchQueue(label: "io.appsynk.netmon")
    private var _current = "unknown"

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type: String
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi)              { type = "wifi" }
                else if path.usesInterfaceType(.cellular)     { type = "cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { type = "ethernet" }
                else                                           { type = "other" }
            } else {
                type = "disconnected"
            }
            // The handler runs on `queue` (serial); the getter syncs onto the same queue, so all
            // access to `_current` is serialized — no data race.
            self._current = type
        }
        monitor.start(queue: queue)
        #endif
    }

    /// Latest observed connectivity: wifi | cellular | ethernet | other | disconnected | unknown.
    var current: String { queue.sync { _current } }
}

// MARK: - DeviceData

/// The collected `device` + `attribution` wire blocks, plus the custom User-Agent.
///
/// Only `device` and `attribution` are encoded (they are the event sub-blocks). `userAgent` is sent
/// as an HTTP header — the backend reads UA server-side — so it is deliberately excluded from the body.
public struct DeviceData: Encodable {
    public let device: DeviceInfo
    public let attribution: AttributionInfo
    public let userAgent: String

    private enum CodingKeys: String, CodingKey {
        case device, attribution
    }
}

// MARK: - DeviceDataCollector

/// Produces the `device` block + `attribution` sub-block at the backend's exact wire-format.
///
/// Static hardware/locale fields are captured once at init (call from the main thread, e.g. during
/// `configure()`); the dynamic fields — `networkType` (live monitor) and `idfa` (ATT-dependent) —
/// are re-read on every `collect()`. This collector **never** triggers the ATT prompt; it only
/// reads the current authorization via `ATTManager.idfa` (the dev calls
/// `requestTrackingAuthorization` at the right moment).
final class DeviceDataCollector {

    // Cached static fields (do not change during a session).
    private let model: String
    private let deviceType: String
    private let locale: String
    private let timezone: String
    private let screenResolution: String
    private let screenDensity: Int
    private let hasTelephony: Bool
    private let carrier: String?
    private let batteryLevel: Int
    private let idfv: String?
    private let userAgent: String

    init() {
        // Start the shared connectivity monitor (idempotent — first access wins).
        _ = NetworkTypeMonitor.shared

        let deviceType: String
        let idfv: String?
        let batteryLevel: Int
        let screenResolution: String
        let screenDensity: Int

        #if canImport(UIKit)
        let uiDevice = UIDevice.current
        uiDevice.isBatteryMonitoringEnabled = true
        deviceType = uiDevice.userInterfaceIdiom == .pad ? "tablet" : "phone"
        idfv = uiDevice.identifierForVendor?.uuidString
        let rawBattery = uiDevice.batteryLevel
        batteryLevel = rawBattery < 0 ? -1 : Int((rawBattery * 100).rounded())
        let screen = UIScreen.main
        screenResolution = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
        screenDensity = Int(screen.scale)
        #else
        deviceType = "phone"
        idfv = nil
        batteryLevel = -1
        screenResolution = "0x0"
        screenDensity = 0
        #endif

        self.model = Self.hardwareModelIdentifier()
        self.deviceType = deviceType
        self.locale = Locale.current.identifier
        self.timezone = TimeZone.current.identifier
        self.screenResolution = screenResolution
        self.screenDensity = screenDensity
        self.hasTelephony = Self.detectTelephony()
        self.carrier = Self.detectCarrier()
        self.batteryLevel = batteryLevel
        self.idfv = idfv
        self.userAgent = Self.makeUserAgent()
    }

    /// Build a fresh device + attribution snapshot. `networkType` and `idfa` reflect the moment of
    /// the call; everything else is the cached static capture.
    func collect(options: AppSynkOptions, adServicesToken: String? = nil) -> DeviceData {
        let device = DeviceInfo(
            model: model,
            manufacturer: "Apple",
            deviceType: deviceType,
            locale: locale,
            timezone: timezone,
            networkType: NetworkTypeMonitor.shared.current,
            screenResolution: screenResolution,
            carrier: carrier,
            batteryLevel: batteryLevel,
            screenDensity: screenDensity,
            hasTelephony: hasTelephony
        )

        let attribution = AttributionInfo(
            // idfa only when ATT is authorized AND not disabled (ATTManager.idfa is nil unless authorized).
            idfa: options.disableIdfa ? nil : ATTManager.idfa,
            idfv: options.disableIdfv ? nil : idfv,
            skAdNetworkVersion: options.disableSKAdNetwork ? nil : Self.skAdNetworkVersion(),
            // Last SKAN conversion value the SDK applied (backend audit / consistency).
            skanConversionValueApplied: options.disableSKAdNetwork ? nil : SKAdNetworkManager.appliedConversionValue,
            // Apple Search Ads token — captured by the facade at install / first app_open and passed
            // in here (never on every event). The SDK only carries it; the backend exchanges it.
            adServicesToken: options.disableAdServices ? nil : adServicesToken
        )

        return DeviceData(device: device, attribution: attribution, userAgent: userAgent)
    }

    // MARK: - Static helpers

    /// Custom User-Agent: `AppSynk-iOS/{appVersion} ({model}; iOS {osVersion}; Build/{build})`.
    /// Shared with `NetworkService` so the header value has a single definition.
    static func makeUserAgent() -> String {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let model = hardwareModelIdentifier()
        #if canImport(UIKit)
        let osVersion = UIDevice.current.systemVersion
        #else
        let osVersion = "0.0.0"
        #endif
        return "AppSynk-iOS/\(appVersion) (\(model); iOS \(osVersion); Build/\(build))"
    }

    /// SKAdNetwork version supported by this OS, reported in the attribution block.
    static func skAdNetworkVersion() -> String {
        if #available(iOS 16.1, *) { return "4.0" }
        if #available(iOS 14.5, *) { return "3.0" }
        return "2.2"
    }

    /// Precise hardware identifier via `uname` — e.g. "iPhone15,2" on device, "arm64" on simulator.
    /// (`UIDevice.current.model` only returns the generic "iPhone".)
    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    /// True when a cellular radio is present (false on Wi-Fi-only iPad / simulator) — a fraud signal.
    private static func detectTelephony() -> Bool {
        #if canImport(CoreTelephony)
        let radios = CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology
        return !(radios?.isEmpty ?? true)
        #else
        return false
        #endif
    }

    /// Carrier name. `CTCarrier` is deprecated (iOS 16) and returns placeholder data ("--") on most
    /// configs even earlier, so the carrier is intentionally omitted (the backend treats it as
    /// nullable). Kept as a hook should a non-deprecated source appear.
    private static func detectCarrier() -> String? {
        nil
    }
}
