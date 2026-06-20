import XCTest
@testable import AppSynk

/// Verifies a serialized `AppSynkEvent` matches the backend `EventIngestionRequest` wire-format
/// field-for-field (Prompt 3), and that mixed-type `properties` round-trip without loss.
final class EventWireFormatTests: XCTestCase {

    private func encode(_ event: AppSynkEvent) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleEvent(
        properties: [String: Any],
        consent: ConsentPayload? = nil
    ) -> AppSynkEvent {
        let device = DeviceInfo(
            model: "iPhone15,2", manufacturer: "Apple", deviceType: "phone",
            locale: "fr_FR", timezone: "Europe/Paris", networkType: "wifi",
            screenResolution: "393x852", carrier: nil,
            batteryLevel: 87, screenDensity: 3, hasTelephony: true
        )
        return AppSynkEvent(
            deviceId: "device-1",
            appId: "com.example.app",
            eventName: "purchase",
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            platform: "ios",
            osVersion: "17.4",
            appVersion: "2.1.0",
            device: device,
            attribution: AttributionInfo(idfv: "IDFV", skAdNetworkVersion: "4.0"),
            properties: properties,
            consent: consent,
            isAnonymized: false
        )
    }

    func testEventTopLevelKeysMatchContract() throws {
        let event = sampleEvent(
            properties: ["amount": 4.99],
            consent: ConsentPayload(
                isUserSubjectToGDPR: true, hasConsentForDataUsage: true,
                hasConsentForAdsPersonalization: false, consentTimestamp: "2026-06-19T00:00:00Z"
            )
        )
        let json = try encode(event)

        XCTAssertEqual(Set(json.keys), [
            "clientEventId", "deviceId", "appId", "eventName", "timestamp",
            "platform", "osVersion", "appVersion", "device", "attribution",
            "properties", "consent", "isAnonymized"
        ])

        // Exact sub-object wire names — NOT deviceInfo / attributionInfo.
        XCTAssertNotNil(json["device"] as? [String: Any])
        XCTAssertNotNil(json["attribution"] as? [String: Any])

        // clientEventId auto-generated.
        XCTAssertFalse((json["clientEventId"] as? String ?? "").isEmpty)

        // timestamp is ISO 8601 UTC.
        let ts = try XCTUnwrap(json["timestamp"] as? String)
        XCTAssertTrue(ts.contains("T") && ts.hasSuffix("Z"), "timestamp not ISO 8601 UTC: \(ts)")

        let consent = try XCTUnwrap(json["consent"] as? [String: Any])
        XCTAssertEqual(consent["isUserSubjectToGDPR"] as? Bool, true)
        XCTAssertEqual(consent["hasConsentForAdsPersonalization"] as? Bool, false)
        XCTAssertEqual(consent["consentTimestamp"] as? String, "2026-06-19T00:00:00Z")
    }

    func testNilConsentIsOmitted() throws {
        let json = try encode(sampleEvent(properties: [:], consent: nil))
        XCTAssertNil(json["consent"])
        XCTAssertEqual(json["isAnonymized"] as? Bool, false)
    }

    func testMixedTypePropertiesSerializeWithoutLoss() throws {
        let json = try encode(sampleEvent(properties: [
            "amount": 4.99,
            "currency": "USD",
            "quantity": 2,
            "isGift": true,
            "tags": ["a", "b"],
            "meta": ["nested": 1],
            "note": NSNull()
        ]))
        let props = try XCTUnwrap(json["properties"] as? [String: Any])

        XCTAssertEqual(props["amount"] as? Double, 4.99)
        XCTAssertEqual(props["currency"] as? String, "USD")
        XCTAssertEqual(props["quantity"] as? Int, 2)
        XCTAssertEqual(props["isGift"] as? Bool, true)

        // Arrays and nested objects must NOT collapse to null (the old AnyCodable bug).
        let tags = try XCTUnwrap(props["tags"] as? [Any])
        XCTAssertEqual(tags.compactMap { $0 as? String }, ["a", "b"])
        let meta = try XCTUnwrap(props["meta"] as? [String: Any])
        XCTAssertEqual(meta["nested"] as? Int, 1)
        XCTAssertTrue(props["note"] is NSNull)
    }

    func testEachConstructedEventHasUniqueClientEventId() {
        let a = sampleEvent(properties: [:])
        let b = sampleEvent(properties: [:])
        XCTAssertNotEqual(a.clientEventId, b.clientEventId)
    }
}
