import Foundation
import XCTest
@testable import MediTrack

final class APIClientTests: XCTestCase {
    func testGETDecodesSnakeCaseAndOptionalEndDate() async throws {
        let json = """
        {"medications":[{"id":"med_001","name":"Metformin","dosage":"500 mg","instructions":"Take after food",
        "schedule":["08:00","20:00"],"start_date":"2026-11-01","end_date":null}]}
        """
        let transport = RecordingTransport(status: 200, body: Data(json.utf8))
        let api = APIClient(baseURL: Self.baseURL, transport: transport)
        let medications = try await api.medications()
        let requests = await transport.requests
        XCTAssertEqual(medications, [TestValues.medication()])
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/medications")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testPOSTEncodesSnakeCaseISO8601AndStableIdempotencyKey() async throws {
        let transport = RecordingTransport(status: 201)
        let api = APIClient(baseURL: Self.baseURL, transport: transport)
        var log = TestValues.log()
        try await api.submit(log)
        RetryPolicy.reserveAttempt(for: &log, now: log.loggedAt)
        try await api.submit(log)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/dose-logs")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(Data(base64Encoded: key), Data(log.id.utf8))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), key)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, [
            "medication_id": "med_001", "status": "taken",
            "scheduled_at": "2026-11-23T08:00:00Z", "logged_at": "2026-11-23T08:02:08Z"
        ])
    }

    func testRejectsInvalidSchedulesAndSurfacesHTTP500() async throws {
        let json = """
        {"medications":[{"id":"bad","name":"Bad","dosage":"500 mg","instructions":"",
        "schedule":["25:00"],"start_date":"2026-02-31","end_date":null}]}
        """
        let invalid = APIClient(baseURL: Self.baseURL, transport: RecordingTransport(status: 200, body: Data(json.utf8)))
        do {
            _ = try await invalid.medications()
            XCTFail("An invalid fixture must not replace the cached list.")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidMedications)
        }

        let failing = APIClient(baseURL: Self.baseURL, transport: RecordingTransport(status: 500))
        do {
            try await failing.submit(TestValues.log())
            XCTFail("HTTP 500 must leave the log queued.")
        } catch {
            XCTAssertEqual(error as? APIError, .http(500))
        }
    }

    func testMockAcceptsIdempotentReplayAndRejectsDifferentDecisionForSameKey() async throws {
        let mock = ClinicMockTransport(fixture: Data()) { true }
        let api = APIClient(baseURL: Self.baseURL, transport: mock)
        try await api.submit(TestValues.log())
        try await api.submit(TestValues.log())
        do {
            try await api.submit(TestValues.log(decision: .skipped))
            XCTFail("A different payload with the same key must fail.")
        } catch {
            XCTAssertEqual(error as? APIError, .http(409))
        }
    }

    private static let baseURL = URL(string: "https://clinic.example")!
}

private actor RecordingTransport: HTTPTransport {
    let status: Int
    let body: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(status: status, body: body)
    }
}
