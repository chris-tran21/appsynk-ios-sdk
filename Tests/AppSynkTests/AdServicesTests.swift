import XCTest
@testable import AppSynk

/// AdServices token capture + embedding (Prompt 7). The real token requires an App Store / Search
/// Ads install on a device, so here we verify the provider never crashes and that the collector
/// embeds / drops the token according to disableAdServices. (@MainActor: the collector reads UIScreen.)
@MainActor
final class AdServicesTests: XCTestCase {

    func testTokenProviderNeverCrashes() {
        // Simulator → AAAttribution throws → nil; device → may return a token. Either way: no crash.
        _ = AdServicesTokenProvider.token()
    }

    func testCollectorEmbedsTokenWhenEnabled() {
        var options = AppSynkOptions()
        options.disableAdServices = false
        let data = DeviceDataCollector().collect(options: options, adServicesToken: "TOKEN-123")
        XCTAssertEqual(data.attribution.adServicesToken, "TOKEN-123")
    }

    func testCollectorDropsTokenWhenDisabled() {
        var options = AppSynkOptions()
        options.disableAdServices = true
        let data = DeviceDataCollector().collect(options: options, adServicesToken: "TOKEN-123")
        XCTAssertNil(data.attribution.adServicesToken)
    }

    func testTokenAbsentByDefault() {
        // No token passed → field stays nil (not sent on ordinary events).
        let data = DeviceDataCollector().collect(options: AppSynkOptions())
        XCTAssertNil(data.attribution.adServicesToken)
    }
}
