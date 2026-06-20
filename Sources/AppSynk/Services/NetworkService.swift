import Foundation
import CryptoKit

// MARK: - RequestSigner

/// Optional HMAC-SHA256 request signing (CryptoKit). Mirrors the LinkRunner scheme:
///   canonical = "{timestampMs}\n{base64(sha256(payload))}"
///   signature = base64(HMAC-SHA256(canonical, secretKey))
/// Empty body → empty content hash. Returns the four headers to attach, or is simply never built
/// when no HMAC credentials are configured (then requests go out unsigned).
struct RequestSigner {
    let secretKey: String
    let keyId: String

    func sign(payload: Data, timestampMs: Int64) -> [String: String] {
        let contentHash = payload.isEmpty
            ? ""
            : Data(SHA256.hash(data: payload)).base64EncodedString()
        let canonical = "\(timestampMs)\n\(contentHash)"
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        let signature = Data(mac).base64EncodedString()
        return [
            "Authorization": "HMAC",
            "x-Key-Id":      keyId,
            "x-Timestamp":   String(timestampMs),
            "x-Signature":   signature
        ]
    }
}

// MARK: - RetryPolicy

/// Adjust-style exponential backoff. Retries transient failures only: HTTP 429 / 5xx and a small set
/// of recoverable `URLError`s. Permanent client errors (400/401/402/403) are never retried.
struct RetryPolicy {
    let maxRetries: Int
    let baseDelay: TimeInterval

    /// 4 retries after the initial attempt; backoff 2s, 4s, 8s, 16s.
    static let `default` = RetryPolicy(maxRetries: 4, baseDelay: 2.0)

    /// Backoff before retry `n` (1-based): baseDelay · 2^(n-1) → 2, 4, 8, 16 for baseDelay 2.
    func delay(forRetry retry: Int) -> TimeInterval {
        baseDelay * pow(2.0, Double(max(0, retry - 1)))
    }

    func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - NetworkService

/// HTTP client for the AppSynk API: a dedicated ephemeral `URLSession` (no shared cookies/cache with
/// the host app), all endpoints, exponential retry, and optional HMAC signing.
public actor NetworkService {
    private let apiKey: String
    private let options: AppSynkOptions
    private let session: URLSession
    private let signer: RequestSigner?
    private let retryPolicy: RetryPolicy
    private let userAgent: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(apiKey: String, options: AppSynkOptions) {
        self.apiKey = apiKey
        self.options = options

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        self.retryPolicy = .default
        self.userAgent = DeviceDataCollector.makeUserAgent()

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601   // ISO 8601 UTC timestamps; default (camelCase) keys
        self.encoder = enc
        self.decoder = JSONDecoder()

        // Sign only when BOTH credentials are present and non-empty; otherwise requests go unsigned.
        if let secret = options.hmacSecretKey, let keyId = options.hmacKeyId,
           !secret.isEmpty, !keyId.isEmpty {
            self.signer = RequestSigner(secretKey: secret, keyId: keyId)
        } else {
            self.signer = nil
        }
    }

    // MARK: - Endpoints

    /// POST /v1/events — single event. 202 = accepted.
    public func ingest(_ event: AppSynkEvent) async throws {
        let body = try encoder.encode(event)
        let (data, http) = try await perform(method: "POST", path: "v1/events", body: body)
        try validate(http, data)
    }

    /// POST /v1/events/batch — up to 100 events. 202 = accepted.
    public func ingestBatch(_ events: [AppSynkEvent]) async throws {
        guard !events.isEmpty else { return }
        let body = try encoder.encode(BatchPayload(events: events))
        let (data, http) = try await perform(method: "POST", path: "v1/events/batch", body: body)
        try validate(http, data)
    }

    /// GET /v1/ping — connectivity + API key check (200 valid / 401 invalid).
    public func ping() async throws -> PingResponse {
        let (data, http) = try await perform(method: "GET", path: "v1/ping", body: nil)
        try validate(http, data)
        return try decoder.decode(PingResponse.self, from: data)
    }

    /// GET /v1/sdk/init?bundleId= — validates key + bundleId, returns plan + environment.
    public func sdkInit(bundleId: String) async throws -> SdkInitResponse {
        let (data, http) = try await perform(
            method: "GET",
            path: "v1/sdk/init",
            query: [URLQueryItem(name: "bundleId", value: bundleId)],
            body: nil
        )
        try validate(http, data)
        return try decoder.decode(SdkInitResponse.self, from: data)
    }

    /// POST /v1/sdk/skan-value — server-computed SKAdNetwork conversion value for a revenue event.
    public func skanValue(amount: Double, currency: String, eventType: String) async throws -> SkanValueResponse {
        let body = try encoder.encode(SkanValueRequest(amount: amount, currency: currency, eventType: eventType))
        let (data, http) = try await perform(method: "POST", path: "v1/sdk/skan-value", body: body)
        try validate(http, data)
        return try decoder.decode(SkanValueResponse.self, from: data)
    }

    /// POST /v1/attribution/adservices — submits the Apple Search Ads token for backend exchange.
    /// 202 = queued (the worker resolves it against Apple).
    public func postAdServicesToken(deviceId: String, appId: String, token: String) async throws {
        let body = try encoder.encode(AdServicesTokenRequest(deviceId: deviceId, appId: appId, token: token))
        let (data, http) = try await perform(method: "POST", path: "v1/attribution/adservices", body: body)
        try validate(http, data)
    }

    /// GET /v1/links/{linkId}/attribution — resolves a tracking link's campaign data for deep linking.
    public func resolveLinkAttribution(linkId: String) async throws -> AttributionData {
        let (data, http) = try await perform(method: "GET", path: "v1/links/\(linkId)/attribution", body: nil)
        try validate(http, data)
        return try decoder.decode(LinkAttributionResponse.self, from: data).toAttributionData()
    }

    // MARK: - Request execution + retry

    /// Sends the request, retrying transient failures with exponential backoff. The request is
    /// rebuilt (and re-signed with a fresh timestamp) on each attempt, so HMAC stays valid on retries.
    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = makeURL(path: path, query: query)
        var attempt = 0

        while true {
            let request = makeRequest(url: url, method: method, body: body)
            do {
                let (data, response) = try await sessionData(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                if retryPolicy.shouldRetry(statusCode: http.statusCode), attempt < retryPolicy.maxRetries {
                    attempt += 1
                    log("HTTP \(http.statusCode) on /\(path) — retry \(attempt)/\(retryPolicy.maxRetries) in \(retryPolicy.delay(forRetry: attempt))s")
                    try await Task.sleep(nanoseconds: backoffNanoseconds(attempt))
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                if retryPolicy.shouldRetry(error: error), attempt < retryPolicy.maxRetries {
                    attempt += 1
                    log("Network error \(error.code.rawValue) on /\(path) — retry \(attempt)/\(retryPolicy.maxRetries) in \(retryPolicy.delay(forRetry: attempt))s")
                    try await Task.sleep(nanoseconds: backoffNanoseconds(attempt))
                    continue
                }
                throw error
            }
        }
    }

    /// iOS 14 fallback: the async `URLSession.data(for:)` is iOS 15+, so below that we wrap the
    /// completion-handler API in a continuation. Errors still surface as `URLError` for retry.
    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, *) {
            return try await session.data(for: request)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: NetworkError.invalidResponse)
                    }
                }
                task.resume()
            }
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]?) -> URL {
        let base = (options.customApiUrl ?? options.environment.baseUrl).appendingPathComponent(path)
        guard let query, !query.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = query
        return components.url ?? base
    }

    /// Builds a request with the standard headers and, when configured, the HMAC signature headers.
    private func makeRequest(url: URL, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(AppSynkConstants.sdkVersion, forHTTPHeaderField: "X-SDK-Version")
        request.setValue(AppSynkConstants.platform, forHTTPHeaderField: "X-SDK-Platform")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Custom UA — the backend reads the User-Agent server-side for probabilistic matching.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        if let signer {
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            for (field, value) in signer.sign(payload: body ?? Data(), timestampMs: timestampMs) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private func backoffNanoseconds(_ retry: Int) -> UInt64 {
        UInt64(retryPolicy.delay(forRetry: retry) * 1_000_000_000)
    }

    private func validate(_ http: HTTPURLResponse, _ data: Data) throws {
        switch http.statusCode {
        case 200, 202:
            return
        case 400:
            throw NetworkError.badRequest(String(data: data, encoding: .utf8) ?? "")
        case 401:
            throw NetworkError.unauthorized
        case 402:
            throw NetworkError.paymentRequired
        case 403:
            throw NetworkError.forbidden
        case 429:
            throw NetworkError.rateLimited
        default:
            throw NetworkError.serverError(http.statusCode)
        }
    }

    private func log(_ message: String) {
        if options.logLevel != .none {
            print("[AppSynk] \(message)")
        }
    }
}

// MARK: - Wire payloads / responses

private struct BatchPayload: Encodable {
    let events: [AppSynkEvent]
}

private struct SkanValueRequest: Encodable {
    let amount: Double
    let currency: String
    let eventType: String
}

private struct AdServicesTokenRequest: Encodable {
    let deviceId: String
    let appId: String
    let token: String
}

/// GET /v1/ping response (extra fields like `timestamp` are ignored).
public struct PingResponse: Decodable {
    public let status: String
    public let environment: String
}

/// GET /v1/sdk/init response (subset; `appDbId` is ignored).
public struct SdkInitResponse: Decodable {
    public let appId: String
    public let appName: String
    public let environment: String
    public let plan: String
    public let isActive: Bool
}

/// POST /v1/sdk/skan-value response (subset).
public struct SkanValueResponse: Decodable {
    public let conversionValue: Int
    public let revenueTier: Int
    public let eventType: Int
    public let estimatedRevenueUsd: Double
}

/// Wire shape of GET /v1/links/{linkId}/attribution, mapped to the SDK's `AttributionData`.
/// Backend keys differ from the model (adSet/creative/networkClickId/matchType/isAttributed).
struct LinkAttributionResponse: Decodable {
    let channel: String?
    let campaignName: String?
    let adSet: String?
    let creative: String?
    let matchType: String?
    let confidenceScore: Double?
    let networkClickId: String?
    let clickTimestamp: String?
    let deepLink: String?
    let isAttributed: Bool?

    func toAttributionData() -> AttributionData {
        AttributionData(
            channel: channel,
            campaignName: campaignName,
            adSetName: adSet,
            creativeName: creative,
            medium: nil,
            source: channel,
            clickId: networkClickId,
            clickTimestamp: clickTimestamp.flatMap { ISO8601DateFormatter().date(from: $0) },
            isOrganic: !(isAttributed ?? false),
            attributionModel: matchType,
            confidenceScore: confidenceScore,
            deepLink: deepLink
        )
    }
}

// MARK: - Errors

public enum NetworkError: Error, LocalizedError {
    case invalidResponse
    case badRequest(String)
    case unauthorized
    case paymentRequired
    case forbidden
    case rateLimited
    case serverError(Int)

    /// Permanent client errors must not be retried (and should drop the event, not re-queue it).
    public var isPermanentClientError: Bool {
        switch self {
        case .badRequest, .unauthorized, .paymentRequired, .forbidden:
            return true
        case .invalidResponse, .rateLimited, .serverError:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:       return "Invalid server response."
        case .badRequest(let msg):   return "Bad request: \(msg)"
        case .unauthorized:          return "Invalid API key."
        case .paymentRequired:       return "Quota exhausted (402)."
        case .forbidden:             return "App inactive — data collection paused (403)."
        case .rateLimited:           return "Rate limit exceeded. Events will be retried."
        case .serverError(let code): return "Server error \(code)."
        }
    }
}
