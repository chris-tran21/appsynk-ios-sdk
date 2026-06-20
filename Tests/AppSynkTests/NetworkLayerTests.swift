import XCTest
import CryptoKit
@testable import AppSynk

/// Pure-logic tests for the network layer (Prompt 4): HMAC signing + retry policy. The actual
/// URLSession round-trips need a device/simulator + a mock server, so they live outside unit tests.
final class NetworkLayerTests: XCTestCase {

    // MARK: - RequestSigner (HMAC)

    func testSignerProducesExactlyTheFourHmacHeaders() {
        let headers = RequestSigner(secretKey: "secret", keyId: "key-1")
            .sign(payload: Data(#"{"a":1}"#.utf8), timestampMs: 1_700_000_000_000)

        XCTAssertEqual(Set(headers.keys), ["Authorization", "x-Key-Id", "x-Timestamp", "x-Signature"])
        XCTAssertEqual(headers["Authorization"], "HMAC")
        XCTAssertEqual(headers["x-Key-Id"], "key-1")
        XCTAssertEqual(headers["x-Timestamp"], "1700000000000")
        XCTAssertFalse(headers["x-Signature"]?.isEmpty ?? true)
    }

    func testSignatureMatchesCanonicalString() {
        let secret = "topsecret"
        let payload = Data("hello".utf8)
        let ts: Int64 = 1_700_000_000_000

        let signature = RequestSigner(secretKey: secret, keyId: "k")
            .sign(payload: payload, timestampMs: ts)["x-Signature"]

        // Recompute independently: canonical = "{ts}\n{base64(sha256(payload))}".
        let contentHash = Data(SHA256.hash(data: payload)).base64EncodedString()
        let canonical = "\(ts)\n\(contentHash)"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        XCTAssertEqual(signature, Data(mac).base64EncodedString())
    }

    func testEmptyPayloadUsesEmptyContentHash() {
        let ts: Int64 = 42
        let signature = RequestSigner(secretKey: "s", keyId: "k")
            .sign(payload: Data(), timestampMs: ts)["x-Signature"]

        let canonical = "\(ts)\n"   // empty body → empty content hash
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: SymmetricKey(data: Data("s".utf8))
        )
        XCTAssertEqual(signature, Data(mac).base64EncodedString())
    }

    // MARK: - RetryPolicy

    func testBackoffSequenceIs2_4_8_16() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.maxRetries, 4)
        XCTAssertEqual(policy.delay(forRetry: 1), 2)
        XCTAssertEqual(policy.delay(forRetry: 2), 4)
        XCTAssertEqual(policy.delay(forRetry: 3), 8)
        XCTAssertEqual(policy.delay(forRetry: 4), 16)
    }

    func testRetryableStatusCodes() {
        let policy = RetryPolicy.default
        for code in [429, 500, 502, 503] {
            XCTAssertTrue(policy.shouldRetry(statusCode: code), "expected retry on \(code)")
        }
        for code in [200, 202, 400, 401, 402, 403] {
            XCTAssertFalse(policy.shouldRetry(statusCode: code), "did not expect retry on \(code)")
        }
    }

    func testRetryableNetworkErrors() {
        let policy = RetryPolicy.default
        let retryable: [URLError.Code] = [
            .notConnectedToInternet, .timedOut, .networkConnectionLost,
            .cannotConnectToHost, .dnsLookupFailed
        ]
        for code in retryable {
            XCTAssertTrue(policy.shouldRetry(error: URLError(code)), "expected retry on \(code)")
        }
        XCTAssertFalse(policy.shouldRetry(error: URLError(.badURL)))
        XCTAssertFalse(policy.shouldRetry(error: NetworkError.unauthorized))
    }

    // MARK: - Error classification

    func testPermanentClientErrors() {
        XCTAssertTrue(NetworkError.unauthorized.isPermanentClientError)
        XCTAssertTrue(NetworkError.paymentRequired.isPermanentClientError)
        XCTAssertTrue(NetworkError.forbidden.isPermanentClientError)
        XCTAssertTrue(NetworkError.badRequest("x").isPermanentClientError)
        XCTAssertFalse(NetworkError.rateLimited.isPermanentClientError)
        XCTAssertFalse(NetworkError.serverError(503).isPermanentClientError)
    }
}
