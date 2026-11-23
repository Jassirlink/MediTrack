import Foundation

protocol ClinicAPI: Sendable {
    func medications() async throws -> [Medication]
    func submit(_ log: DoseLog) async throws
}

struct HTTPResponse: Sendable {
    let status: Int
    let body: Data
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

enum APIError: LocalizedError, Equatable {
    case http(Int)
    case invalidResponse
    case invalidMedications

    var errorDescription: String? {
        switch self {
        case .http(let status): "The clinic returned HTTP \(status)."
        case .invalidResponse: "The clinic response could not be read."
        case .invalidMedications: "The clinic sent an invalid medication schedule."
        }
    }
}

struct APIClient: ClinicAPI {
    let baseURL: URL
    let transport: any HTTPTransport

    func medications() async throws -> [Medication] {
        let request = URLRequest(url: baseURL.appending(path: "api/v1/medications"))
        let response = try await transport.send(request)
        guard response.status == 200 else { throw APIError.http(response.status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let medications = try decoder.decode(MedicationsEnvelope.self, from: response.body).medications
        guard Set(medications.map(\.id)).count == medications.count,
              medications.allSatisfy(\.hasValidSchedule) else { throw APIError.invalidMedications }
        return medications
    }

    func submit(_ log: DoseLog) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: baseURL.appending(path: "api/v1/dose-logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Data(log.id.utf8).base64EncodedString(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try encoder.encode(DoseLogPayload(
            medicationId: log.occurrence.medicationID, scheduledAt: log.occurrence.scheduledAt,
            status: log.decision, loggedAt: log.loggedAt
        ))
        let response = try await transport.send(request)
        guard response.status == 201 else { throw APIError.http(response.status) }
    }

    private struct MedicationsEnvelope: Codable {
        let medications: [Medication]
    }

    fileprivate struct DoseLogPayload: Codable, Equatable {
        let medicationId: String
        let scheduledAt: Date
        let status: DoseDecision
        let loggedAt: Date
    }
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}

actor ClinicMockTransport: HTTPTransport {
    private let fixture: Data
    private let succeeds: @Sendable () -> Bool
    private var accepted: [String: APIClient.DoseLogPayload] = [:]

    init(fixture: Data, succeeds: @escaping @Sendable () -> Bool = { Int.random(in: 0..<10) < 7 }) {
        self.fixture = fixture
        self.succeeds = succeeds
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/medications"):
            return HTTPResponse(status: 200, body: fixture)
        case ("POST", "/api/v1/dose-logs"):
            try await Task.sleep(for: .milliseconds(300))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let key = request.value(forHTTPHeaderField: "Idempotency-Key"),
                  let data = request.httpBody,
                  let payload = try? decoder.decode(APIClient.DoseLogPayload.self, from: data) else {
                return HTTPResponse(status: 400, body: Data())
            }
            if let previous = accepted[key] {
                return HTTPResponse(status: previous == payload ? 201 : 409, body: Data())
            }
            guard succeeds() else { return HTTPResponse(status: 500, body: Data()) }
            accepted[key] = payload
            return HTTPResponse(status: 201, body: Data())
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }
}
