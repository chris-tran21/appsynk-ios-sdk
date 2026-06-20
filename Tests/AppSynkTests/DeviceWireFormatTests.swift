import XCTest
@testable import AppSynk

/// Verifies the `device` / `attribution` blocks serialize to the backend's EXACT wire-format
/// (Prompt 2). Uses the same encoder configuration as `NetworkService` (default keys + ISO 8601).
final class DeviceWireFormatTests: XCTestCase {

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDeviceInfoEncodesExactWireKeys() throws {
        let device = DeviceInfo(
            model: "iPhone15,2", manufacturer: "Apple", deviceType: "phone",
            locale: "fr_FR", timezone: "Europe/Paris", networkType: "wifi",
            screenResolution: "393x852", carrier: "Orange",
            batteryLevel: 87, screenDensity: 3, hasTelephony: true
        )
        let json = try encodeToObject(device)

        XCTAssertEqual(Set(json.keys), [
            "model", "manufacturer", "deviceType", "locale", "timezone",
            "networkType", "screenResolution", "carrier", "batteryLevel",
            "screenDensity", "hasTelephony"
        ])
        // The precise model identifier, not the generic "iPhone".
        XCTAssertEqual(json["model"] as? String, "iPhone15,2")
        XCTAssertEqual(json["deviceType"] as? String, "phone")
        XCTAssertEqual(json["networkType"] as? String, "wifi")
        XCTAssertEqual(json["screenDensity"] as? Int, 3)
    }

    func testAttributionInfoEncodesWireKeysAndOmitsServerFields() throws {
        var attribution = AttributionInfo(idfv: "IDFV-1", skAdNetworkVersion: "4.0")
        attribution.idfa = "IDFA-1"
        let json = try encodeToObject(attribution)

        XCTAssertEqual(json["idfa"] as? String, "IDFA-1")
        XCTAssertEqual(json["idfv"] as? String, "IDFV-1")
        XCTAssertEqual(json["skAdNetworkVersion"] as? String, "4.0")
        XCTAssertEqual(json["isAnonymized"] as? Bool, false)
        // The SDK must never send IP / User-Agent in the body — the backend fills those.
        XCTAssertNil(json["ipAddress"])
        XCTAssertNil(json["userAgent"])
    }

    func testDeviceDataEncodesOnlyDeviceAndAttribution() throws {
        let device = DeviceInfo(
            model: "arm64", manufacturer: "Apple", deviceType: "phone",
            locale: "en_US", timezone: "UTC", networkType: "wifi",
            screenResolution: "390x844", carrier: nil,
            batteryLevel: -1, screenDensity: 3, hasTelephony: false
        )
        let data = DeviceData(
            device: device,
            attribution: AttributionInfo(),
            userAgent: "AppSynk-iOS/1.0 (arm64; iOS 17.4; Build/1)"
        )
        let json = try encodeToObject(data)

        // userAgent is an HTTP header, never part of the body.
        XCTAssertEqual(Set(json.keys), ["device", "attribution"])
        XCTAssertNotNil(json["device"])
        XCTAssertNotNil(json["attribution"])
    }

    func testUserAgentFormat() {
        let ua = DeviceDataCollector.makeUserAgent()
        XCTAssertTrue(ua.hasPrefix("AppSynk-iOS/"), "Unexpected User-Agent: \(ua)")
        XCTAssertTrue(ua.contains("Build/"), "Unexpected User-Agent: \(ua)")
    }

    /// The precise hardware identifier via uname — "iPhone15,2" on device, "arm64"/"x86_64" on the
    /// simulator — never the generic "iPhone".
    @MainActor
    func testCollectorReportsPreciseHardwareModel() {
        let device = DeviceDataCollector().collect(options: AppSynkOptions()).device
        XCTAssertFalse(device.model.isEmpty)
        XCTAssertNotEqual(device.model, "iPhone")
    }
}
