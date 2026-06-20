import XCTest
@testable import AppSynk

/// Deep linking (Prompt 10): buffer + replay (the AppsFlyer pattern), linkId extraction, and the
/// backend attribution response mapping. End-to-end resolution against the live endpoint is verified
/// manually; here we cover the parts that broke naive bridges.
final class DeepLinkTests: XCTestCase {

    // MARK: - Buffer + replay

    func testCallbackRegisteredBeforeResolutionIsReplayed() {
        let buffer = DeepLinkBuffer()
        let exp = expectation(description: "replayed after deliver")
        buffer.register { data in
            XCTAssertEqual(data?.channel, "tiktok_ads")
            exp.fulfill()
        }
        // Resolution arrives AFTER the callback was registered (cold-start case).
        buffer.deliver(AttributionData(channel: "tiktok_ads"))
        wait(for: [exp], timeout: 2)
    }

    func testCallbackRegisteredAfterResolutionFiresImmediately() {
        let buffer = DeepLinkBuffer()
        buffer.deliver(AttributionData(channel: "meta_ads"))
        let exp = expectation(description: "fires immediately")
        buffer.register { data in
            XCTAssertEqual(data?.channel, "meta_ads")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testSeededBufferReplaysPersistedDeepLink() {
        let buffer = DeepLinkBuffer(seed: AttributionData(channel: "google", campaignName: "pmax"))
        let exp = expectation(description: "seed replayed")
        buffer.register { data in
            XCTAssertEqual(data?.channel, "google")
            XCTAssertEqual(data?.campaignName, "pmax")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testAllBufferedCallbacksAreReplayed() {
        let buffer = DeepLinkBuffer()
        let exp1 = expectation(description: "cb1")
        let exp2 = expectation(description: "cb2")
        buffer.register { _ in exp1.fulfill() }
        buffer.register { _ in exp2.fulfill() }
        buffer.deliver(AttributionData(channel: "apple"))
        wait(for: [exp1, exp2], timeout: 2)
    }

    // MARK: - URL parsing

    func testLinkIdExtraction() {
        XCTAssertEqual(
            DeepLinkResolver.linkId(from: URL(string: "https://go.appsynk.io/fb_AbC123")!), "fb_AbC123")
        XCTAssertEqual(
            DeepLinkResolver.linkId(from: URL(string: "appsynk://go.appsynk.io/tk_X1")!), "tk_X1")
        XCTAssertNil(DeepLinkResolver.linkId(from: URL(string: "https://example.com/foo")!))
        XCTAssertNil(DeepLinkResolver.linkId(from: URL(string: "https://go.appsynk.io/")!))
    }

    // MARK: - Backend response mapping

    func testLinkAttributionResponseMapsBackendKeys() throws {
        let json = """
        {"channel":"tiktok_ads","campaignName":"summer","adSet":"video_a","creative":"c1",
         "matchType":"tracking_link","confidenceScore":1.0,"networkClickId":"clk_1",
         "clickTimestamp":null,"deepLink":"myapp://product/42","isAttributed":true}
        """
        let dto = try JSONDecoder().decode(LinkAttributionResponse.self, from: Data(json.utf8))
        let attribution = dto.toAttributionData()

        XCTAssertEqual(attribution.channel, "tiktok_ads")
        XCTAssertEqual(attribution.campaignName, "summer")
        XCTAssertEqual(attribution.adSetName, "video_a")     // backend "adSet" → adSetName
        XCTAssertEqual(attribution.creativeName, "c1")       // backend "creative" → creativeName
        XCTAssertEqual(attribution.clickId, "clk_1")         // backend "networkClickId" → clickId
        XCTAssertEqual(attribution.attributionModel, "tracking_link")
        XCTAssertEqual(attribution.deepLink, "myapp://product/42")
        XCTAssertEqual(attribution.confidenceScore, 1.0)
        XCTAssertFalse(attribution.isOrganic)                // isAttributed: true → not organic
    }
}
