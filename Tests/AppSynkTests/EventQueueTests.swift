import XCTest
@testable import AppSynk

/// EventQueue behaviour (Prompt 5): batching, disk persistence across "relaunch", stable
/// clientEventId across retries (backend dedup), and the max-queue safety bound. A MockSender is
/// injected via the EventBatchSending protocol, so no real network is needed.
final class EventQueueTests: XCTestCase {

    // MARK: - Mock sender

    private actor MockSender: EventBatchSending {
        private(set) var batches: [[AppSynkEvent]] = []
        private var failure: Error?

        init(failure: Error? = nil) { self.failure = failure }

        func setFailure(_ error: Error?) { self.failure = error }

        func ingestBatch(_ events: [AppSynkEvent]) async throws {
            if let failure { throw failure }
            batches.append(events)
        }

        var batchSizes: [Int] { batches.map(\.count) }
        var totalSent: Int { batches.reduce(0) { $0 + $1.count } }
        var firstSentEvent: AppSynkEvent? { batches.first?.first }
    }

    // MARK: - Helpers

    private func makeOptions(batchSize: Int) -> AppSynkOptions {
        var opts = AppSynkOptions()
        opts.batchSize = batchSize
        opts.flushInterval = 9_999   // keep the periodic timer out of the way; we flush explicitly
        return opts
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("appsynk-queue-\(UUID().uuidString).json")
    }

    private func makeEvent(_ name: String) -> AppSynkEvent {
        AppSynkEvent(
            deviceId: "device-1", appId: "com.example.app", eventName: name,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            platform: "ios", osVersion: "17.4", appVersion: "1.0",
            device: DeviceInfo(model: "arm64", manufacturer: "Apple", deviceType: "phone",
                               locale: "en_US", timezone: "UTC", networkType: "wifi",
                               screenResolution: "1x1", carrier: nil, batteryLevel: -1,
                               screenDensity: 3, hasTelephony: false),
            attribution: AttributionInfo(),
            properties: [:]
        )
    }

    // MARK: - Tests

    func testBatchingProduces10_10_5() async {
        let store = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }

        let sender = MockSender()
        let queue = EventQueue(network: sender, options: makeOptions(batchSize: 10), storeURL: store)

        for i in 0..<25 { await queue.enqueue(makeEvent("e\(i)")) }
        await queue.flush()   // flush the trailing 5

        let sizes = await sender.batchSizes
        XCTAssertEqual(sizes, [10, 10, 5])
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }

    func testEventsSurviveReload() async {
        let store = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }

        // First "launch": sender fails (transient) → events stay queued AND persisted to disk.
        let failing = MockSender(failure: NetworkError.serverError(503))
        let queue1 = EventQueue(network: failing, options: makeOptions(batchSize: 100), storeURL: store)
        for i in 0..<5 { await queue1.enqueue(makeEvent("e\(i)")) }
        await queue1.flush()
        let kept = await queue1.count
        XCTAssertEqual(kept, 5, "a transient failure must keep events queued")

        // Second "launch": fresh queue, same store, succeeding sender → restored events are sent.
        let ok = MockSender()
        let queue2 = EventQueue(network: ok, options: makeOptions(batchSize: 100), storeURL: store)
        let restored = await queue2.count
        XCTAssertEqual(restored, 5, "events must be reloaded from disk after a kill")
        await queue2.flush()
        let sent = await ok.totalSent
        XCTAssertEqual(sent, 5)
        let remaining = await queue2.count
        XCTAssertEqual(remaining, 0)
    }

    func testClientEventIdStableAcrossRetries() async {
        let store = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }

        let sender = MockSender(failure: NetworkError.serverError(503))
        let queue = EventQueue(network: sender, options: makeOptions(batchSize: 100), storeURL: store)

        let event = makeEvent("purchase")
        let originalId = event.clientEventId
        await queue.enqueue(event)
        await queue.flush()             // fails → kept

        await sender.setFailure(nil)
        await queue.flush()             // succeeds → same event re-sent

        let sentId = await sender.firstSentEvent?.clientEventId
        XCTAssertEqual(sentId, originalId, "clientEventId must be stable across retries for backend dedup")
    }

    func testMaxQueueBoundDropsOldest() async {
        let store = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: store) }

        // Huge batchSize so no auto-flush fires while filling; failing sender so nothing is removed.
        let sender = MockSender(failure: NetworkError.serverError(503))
        let queue = EventQueue(network: sender, options: makeOptions(batchSize: 100_000), storeURL: store)

        for i in 0..<1_100 { await queue.enqueue(makeEvent("e\(i)")) }

        let count = await queue.count
        XCTAssertEqual(count, 1000, "queue must cap at maxQueue (1000), dropping the oldest")
    }
}
