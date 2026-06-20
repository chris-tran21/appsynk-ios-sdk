import Foundation

// MARK: - AppSynkEvent

/// A single tracked event, serialized to the backend's exact wire-format.
///
/// Encoded with **default** JSON keys (camelCase): the Swift property names already match the
/// backend contract (`deviceId`, `eventName`, `deviceType`, …), so no key-conversion strategy is
/// applied. Snake-casing would break ingestion and mangle developer-supplied property keys.
public struct AppSynkEvent: Codable {
    /// Client-generated id for idempotent dedup. Created once at event construction and kept
    /// stable across retries (the queued event carries it), so the backend can drop duplicates.
    public let clientEventId: String
    public let deviceId: String
    public let appId: String
    public let eventName: String
    public let timestamp: Date
    public let platform: String
    public let osVersion: String
    public let appVersion: String
    public let device: DeviceInfo
    public let attribution: AttributionInfo
    public var properties: [String: AnyCodable]
    public var consent: ConsentPayload?
    public var isAnonymized: Bool

    /// Exact backend wire names (AppSynk.Api `EventIngestionRequest`). The sub-objects MUST encode
    /// as "device" / "attribution" — "deviceInfo" / "attributionInfo" are silently dropped on ingest.
    enum CodingKeys: String, CodingKey {
        case clientEventId
        case deviceId
        case appId
        case eventName
        case timestamp
        case platform
        case osVersion
        case appVersion
        case device
        case attribution
        case properties
        case consent
        case isAnonymized
    }

    public init(
        clientEventId: String = UUID().uuidString,
        deviceId: String,
        appId: String,
        eventName: String,
        timestamp: Date,
        platform: String,
        osVersion: String,
        appVersion: String,
        device: DeviceInfo,
        attribution: AttributionInfo,
        properties: [String: Any],
        consent: ConsentPayload? = nil,
        isAnonymized: Bool = false
    ) {
        self.clientEventId = clientEventId
        self.deviceId = deviceId
        self.appId = appId
        self.eventName = eventName
        self.timestamp = timestamp
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.device = device
        self.attribution = attribution
        self.properties = properties.mapValues { AnyCodable($0) }
        self.consent = consent
        self.isAnonymized = isAnonymized
    }
}

// MARK: - ConsentPayload (wire block "consent")

/// GDPR consent block sent at the event root. The backend copies these into `AttributionInfo` for
/// postback decisions. Field names match the backend `ConsentPayload` contract verbatim.
public struct ConsentPayload: Codable {
    public let isUserSubjectToGDPR: Bool
    public let hasConsentForDataUsage: Bool
    public let hasConsentForAdsPersonalization: Bool
    public let consentTimestamp: String?   // ISO 8601 UTC

    public init(
        isUserSubjectToGDPR: Bool,
        hasConsentForDataUsage: Bool,
        hasConsentForAdsPersonalization: Bool,
        consentTimestamp: String? = nil
    ) {
        self.isUserSubjectToGDPR = isUserSubjectToGDPR
        self.hasConsentForDataUsage = hasConsentForDataUsage
        self.hasConsentForAdsPersonalization = hasConsentForAdsPersonalization
        self.consentTimestamp = consentTimestamp
    }
}

// MARK: - DeviceInfo (wire block "device")

/// Device hardware + locale block. Field names map 1:1 to the backend `DeviceInfo` contract
/// (`AppSynk.Core.Models.Event`). Populated by `DeviceDataCollector` — this type holds no
/// collection logic so it stays a pure, platform-agnostic data model.
public struct DeviceInfo: Codable {
    public let model: String            // precise hardware id, e.g. "iPhone15,2" (not "iPhone")
    public let manufacturer: String     // "Apple"
    public let deviceType: String       // "phone" | "tablet"
    public let locale: String           // "fr_FR"
    public let timezone: String         // "Europe/Paris"
    public let networkType: String      // wifi | cellular | ethernet | other | disconnected | unknown
    public let screenResolution: String // "393x852"
    public let carrier: String?         // nil on iOS 16+ (CoreTelephony deprecated) / Wi-Fi devices
    public let batteryLevel: Int        // 0–100, or -1 if unavailable (simulator signal)
    public let screenDensity: Int       // UIScreen scale (2 or 3)
    public let hasTelephony: Bool       // false on Wi-Fi-only iPad / simulator

    public init(
        model: String,
        manufacturer: String,
        deviceType: String,
        locale: String,
        timezone: String,
        networkType: String,
        screenResolution: String,
        carrier: String?,
        batteryLevel: Int,
        screenDensity: Int,
        hasTelephony: Bool
    ) {
        self.model = model
        self.manufacturer = manufacturer
        self.deviceType = deviceType
        self.locale = locale
        self.timezone = timezone
        self.networkType = networkType
        self.screenResolution = screenResolution
        self.carrier = carrier
        self.batteryLevel = batteryLevel
        self.screenDensity = screenDensity
        self.hasTelephony = hasTelephony
    }
}

// MARK: - AttributionInfo (wire block "attribution")

/// Attribution identifiers + privacy flags. Field names map 1:1 to the backend `AttributionInfo`
/// contract.
///
/// The SDK never sends `ipAddress` / `userAgent` — the backend fills those from the HTTP request.
/// Device-derived fields (`idfa` / `idfv` / `skAdNetworkVersion` / `adServicesToken`) are set by
/// `DeviceDataCollector`; the remaining fields are overlaid by their owning modules (deep link,
/// consent, SKAN). `gaid` / `androidId` exist for Android symmetry and are always nil on iOS.
public struct AttributionInfo: Codable {
    public var idfa: String?
    public var idfv: String?
    public var gaid: String?
    public var androidId: String?
    public var referrerUrl: String?
    public var clickId: String?
    public var skAdNetworkVersion: String?
    public var metaInstallReferrer: String?
    public var isUserSubjectToGDPR: Bool?
    public var hasConsentForDataUsage: Bool?
    public var hasConsentForAdsPersonalization: Bool?
    public var isAnonymized: Bool
    public var skanConversionValueApplied: Int?
    public var adServicesToken: String?   // Apple Search Ads token — populated in Prompt 7

    public init(
        idfa: String? = nil,
        idfv: String? = nil,
        gaid: String? = nil,
        androidId: String? = nil,
        referrerUrl: String? = nil,
        clickId: String? = nil,
        skAdNetworkVersion: String? = nil,
        metaInstallReferrer: String? = nil,
        isUserSubjectToGDPR: Bool? = nil,
        hasConsentForDataUsage: Bool? = nil,
        hasConsentForAdsPersonalization: Bool? = nil,
        isAnonymized: Bool = false,
        skanConversionValueApplied: Int? = nil,
        adServicesToken: String? = nil
    ) {
        self.idfa = idfa
        self.idfv = idfv
        self.gaid = gaid
        self.androidId = androidId
        self.referrerUrl = referrerUrl
        self.clickId = clickId
        self.skAdNetworkVersion = skAdNetworkVersion
        self.metaInstallReferrer = metaInstallReferrer
        self.isUserSubjectToGDPR = isUserSubjectToGDPR
        self.hasConsentForDataUsage = hasConsentForDataUsage
        self.hasConsentForAdsPersonalization = hasConsentForAdsPersonalization
        self.isAnonymized = isAnonymized
        self.skanConversionValueApplied = skanConversionValueApplied
        self.adServicesToken = adServicesToken
    }

    /// A copy with personal identifiers stripped and `isAnonymized` set — used in anonymized mode.
    /// Non-identifying signals (e.g. skAdNetworkVersion) are preserved.
    func anonymizedCopy() -> AttributionInfo {
        var copy = self
        copy.idfa = nil
        copy.idfv = nil
        copy.gaid = nil
        copy.adServicesToken = nil
        copy.isAnonymized = true
        return copy
    }
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for the event's heterogeneous `properties` dictionary.
///
/// Handles scalars (bool/int/double/string), `null`, AND nested arrays / objects — both ways. The
/// previous version silently encoded arrays and nested objects as `null`, dropping data; full
/// round-trip support is also what the on-disk queue (Prompt 4) relies on.
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: nil first, then Bool before Int (JSONDecoder keeps them distinct), then
        // Int before Double, then containers.
        if container.decodeNil() {
            value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            value = v
        } else if let v = try? container.decode(Int.self) {
            value = v
        } else if let v = try? container.decode(Double.self) {
            value = v
        } else if let v = try? container.decode(String.self) {
            value = v
        } else if let v = try? container.decode([AnyCodable].self) {
            value = v.map(\.value)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Int64:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Float:
            try container.encode(Double(v))
        case let v as String:
            try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:
            try container.encode(v.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }
}
