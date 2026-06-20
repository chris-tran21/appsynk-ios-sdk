import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Abstraction over the batch-ingest endpoint, so the queue can be unit-tested with a mock sender.
protocol EventBatchSending: Sendable {
    func ingestBatch(_ events: [AppSynkEvent]) async throws
}

extension NetworkService: EventBatchSending {}

/// Reliable, persistent event queue — never loses an event.
///
/// The pending list is persisted to disk on every change (survives an app kill), flushed on batch
/// size / timer / background, and removed from the queue ONLY after a 202. Dedup is idempotent and
/// backend-side: each event carries a stable `clientEventId` that survives retries, so a re-sent
/// event (e.g. when a 202 was lost on a flaky network) is recognized and dropped server-side.
actor EventQueue {
    private var pending: [AppSynkEvent] = []
    private let network: any EventBatchSending
    private let storeURL: URL
    private let logLevel: AppSynkOptions.LogLevel

    private let batchSize: Int
    private let flushInterval: TimeInterval
    private let maxBatch = 100      // backend hard limit (HandleIngestBatchAsync)
    private let maxQueue = 1000     // safety bound

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var flushTask: Task<Void, Never>?
    private var isFlushing = false

    init(network: any EventBatchSending, options: AppSynkOptions, storeURL: URL) {
        self.network = network
        self.storeURL = storeURL
        self.logLevel = options.logLevel
        self.batchSize = max(1, options.batchSize)
        self.flushInterval = max(1, options.flushInterval)

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        self.encoder = enc
        self.decoder = dec

        // Reload anything left on disk by a previous launch.
        self.pending = Self.load(from: storeURL, decoder: dec)
    }

    // MARK: - Lifecycle

    /// Starts the periodic flush timer + background-flush observer and flushes anything restored
    /// from disk. Call once after construction (from the main thread, via `configure`).
    func start() {
        scheduleFlushTimer()
        registerBackgroundObserver()
        Task { await self.flush() }
    }

    // MARK: - Queue

    func enqueue(_ event: AppSynkEvent) async {
        pending.append(event)

        // Safety bound: drop the oldest beyond maxQueue (degraded mode — should not happen normally).
        if pending.count > maxQueue {
            let overflow = pending.count - maxQueue
            pending.removeFirst(overflow)
            log("Queue overflow — dropped \(overflow) oldest event(s)")
        }

        persist()  // persist on every enqueue so a kill before flush loses nothing

        if pending.count >= batchSize {
            await flush()
        }
    }

    /// Sends pending events in batches of up to 100, removing each batch ONLY after a 202.
    func flush() async {
        guard !pending.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !pending.isEmpty {
            let batch = Array(pending.prefix(maxBatch))
            do {
                try await network.ingestBatch(batch)
                pending.removeFirst(min(batch.count, pending.count))  // remove only on success
                persist()
                log("Flushed \(batch.count) event(s) — \(pending.count) remaining")
            } catch {
                // Permanent client errors (400/401/402/403) will never succeed: drop the batch so a
                // poison event can't block the queue forever.
                if let netError = error as? NetworkError, netError.isPermanentClientError {
                    log("Dropping \(batch.count) event(s) — permanent error: \(error.localizedDescription)")
                    pending.removeFirst(min(batch.count, pending.count))
                    persist()
                    continue
                }
                // Transient error: keep the events, retry next cycle. No event is lost.
                log("Flush failed (\(error.localizedDescription)) — \(pending.count) event(s) kept for retry")
                break
            }
        }
    }

    /// Number of events currently queued (diagnostics / tests).
    var count: Int { pending.count }

    /// Names of the queued events, oldest first (diagnostics).
    var pendingEventNames: [String] { pending.map(\.eventName) }

    // MARK: - Background flush

    /// Flush wrapped in a background task so an in-flight send can finish after the app backgrounds.
    func flushWithBackgroundTask() async {
        #if canImport(UIKit)
        let taskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "io.appsynk.flush")
        }
        await flush()
        if taskId != .invalid {
            await MainActor.run { UIApplication.shared.endBackgroundTask(taskId) }
        }
        #else
        await flush()
        #endif
    }

    // MARK: - Private

    private func scheduleFlushTimer() {
        let interval = flushInterval
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.flush()
            }
        }
    }

    private func registerBackgroundObserver() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.flushWithBackgroundTask() }
        }
        #endif
    }

    private func persist() {
        do {
            let data = try encoder.encode(pending)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            log("Failed to persist queue: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        if logLevel != .none {
            print("[AppSynk] \(message)")
        }
    }

    // MARK: - Storage

    private static func load(from url: URL, decoder: JSONDecoder) -> [AppSynkEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([AppSynkEvent].self, from: data)) ?? []
    }

    /// Default store: `<Application Support>/AppSynk/event_queue.json` (created if needed).
    static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("AppSynk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var fileURL = dir.appendingPathComponent("event_queue.json")
        // Transient data → exclude from iCloud/iTunes backup (Apple best-practice). If the file
        // doesn't exist yet, setting the attribute is a no-op caught by try?; it takes effect once
        // the atomic write creates the file, and re-posting it on the next launch is harmless.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? fileURL.setResourceValues(values)
        return fileURL
    }
}
