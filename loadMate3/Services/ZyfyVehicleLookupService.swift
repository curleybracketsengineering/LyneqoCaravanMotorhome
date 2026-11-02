import Foundation

/// Vehicle lookup through the Lyneqo proxy. The proxy holds the Zyfy key and returns Zyfy's JSON.
final class ZyfyVehicleLookupService: VehicleLookupProviding, @unchecked Sendable {
    static let defaultBaseURL = URL(string: "https://api.lyneqo.com/v1")!

    private let session: URLSession
    private let baseURL: URL
    private let maxEnrichmentAttempts: Int
    private let maxRetryAfterSeconds: TimeInterval

    init(
        session: URLSession = .shared,
        baseURL: URL = defaultBaseURL,
        maxEnrichmentAttempts: Int = 3,
        maxRetryAfterSeconds: TimeInterval = 15
    ) {
        self.session = session
        self.baseURL = baseURL
        self.maxEnrichmentAttempts = max(1, maxEnrichmentAttempts)
        self.maxRetryAfterSeconds = maxRetryAfterSeconds
    }

    func lookup(registration: String, forceRefresh: Bool) async throws -> VehicleLookupResult {
        let normalized = UKRegistration.normalizeForLookup(registration)
        guard !normalized.isEmpty else {
            throw VehicleLookupError.invalidRegistration
        }
        guard let url = lookupURL(registration: normalized) else {
            throw VehicleLookupError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var lastWasPending = false
        for attempt in 1...maxEnrichmentAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw mapTransportError(error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw VehicleLookupError.unexpectedResponse
            }

            if http.statusCode == 429 {
                let mapped = map429(http, data: data)
                debugLog("Zyfy HTTP 429 for \(normalized), attempt \(attempt): \(mapped)")
                if mapped == .quotaExhausted {
                    throw mapped
                }
                if attempt < maxEnrichmentAttempts {
                    try await sleepRetryAfter(http)
                    continue
                }
                throw mapped
            }

            try throwIfUnsuccessful(http, data: data)

            let dto: ZyfyVehicleResponseDTO
            do {
                dto = try ZyfyVehicleLookupMapper.decodeResponse(data)
            } catch {
                debugLog("Zyfy decode failed for \(normalized): \(error.localizedDescription)")
                throw VehicleLookupError.unexpectedResponse
            }

            if dto.enrichmentPending == true {
                lastWasPending = true
                debugLog("Zyfy enrichment pending for \(normalized), attempt \(attempt)")
                if attempt < maxEnrichmentAttempts {
                    try await sleepRetryAfter(http)
                    continue
                }
                throw VehicleLookupError.serviceUnavailable
            }

            return ZyfyVehicleLookupMapper.map(dto, fallbackRegistration: normalized)
        }

        throw lastWasPending ? VehicleLookupError.serviceUnavailable : VehicleLookupError.unexpectedResponse
    }

    private func throwIfUnsuccessful(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }

        let message = ZyfyVehicleLookupMapper.errorMessage(from: data)?.lowercased() ?? ""
        debugLog("Zyfy HTTP \(http.statusCode) for lookup: \(message.isEmpty ? "no error body" : message)")

        switch http.statusCode {
        case 400:
            if message.contains("not_found") || message.contains("not found") {
                throw VehicleLookupError.notFound
            }
            throw VehicleLookupError.invalidRegistration
        case 401, 403, 503:
            throw VehicleLookupError.serviceUnavailable
        case 404:
            throw VehicleLookupError.notFound
        case 429:
            throw map429(http, data: data)
        default:
            throw VehicleLookupError.serviceUnavailable
        }
    }

    /// Zyfy uses 429 for both per-minute rate limits and monthly quota exhaustion.
    private func map429(_ http: HTTPURLResponse, data: Data) -> VehicleLookupError {
        isQuotaExhausted(http, data: data) ? .quotaExhausted : .rateLimited
    }

    private func isQuotaExhausted(_ http: HTTPURLResponse, data: Data) -> Bool {
        let body = ZyfyVehicleLookupMapper.errorBody(from: data)
        let code = body?.code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if code == "quota_exhausted" || code.contains("quota") {
            return true
        }

        let message = (body?.error ?? "").lowercased()
        if message.contains("quota") || message.contains("credit") {
            return true
        }

        if let remaining = http.value(forHTTPHeaderField: "X-Quota-Remaining")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           remaining == "0" {
            return true
        }

        // Monthly reset is typically hours or days; per-minute Retry-After is seconds.
        if let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? ""),
           retryAfter > 120 {
            return true
        }

        return false
    }

    private func mapTransportError(_ error: Error) -> VehicleLookupError {
        if let lookup = error as? VehicleLookupError { return lookup }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .noNetwork
            default:
                return .serviceUnavailable
            }
        }
        return .serviceUnavailable
    }

    private func lookupURL(registration: String) -> URL? {
        let endpoint = baseURL.appending(path: "vehicle")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "registration", value: registration)]
        return components.url
    }

    private func sleepRetryAfter(_ http: HTTPURLResponse) async throws {
        let header = http.value(forHTTPHeaderField: "Retry-After")
        let seconds = min(maxRetryAfterSeconds, max(0, TimeInterval(header ?? "") ?? 3))
        let nanos = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[VehicleLookup] \(message)")
        #endif
    }
}

enum ZyfyVehicleLookupMapper {
    static func decodeResponse(_ data: Data) throws -> ZyfyVehicleResponseDTO {
        try JSONDecoder().decode(ZyfyVehicleResponseDTO.self, from: data)
    }

    static func map(_ dto: ZyfyVehicleResponseDTO, fallbackRegistration: String = "") -> VehicleLookupResult {
        let registration = UKRegistration.normalizeForLookup(dto.registration ?? fallbackRegistration)
        return VehicleLookupResult(
            registration: registration,
            displayRegistration: UKRegistration.displayFormatted(registration),
            make: nonEmpty(dto.make),
            model: nonEmpty(dto.model),
            colour: nonEmpty(dto.colour),
            fuelType: nonEmpty(dto.fuelType),
            vehicleType: nonEmpty(dto.vehicleType),
            yearOfManufacture: dto.yearOfManufacture,
            monthOfFirstRegistration: nonEmpty(dto.monthOfFirstRegistration),
            engineCapacityCc: dto.engineCapacityCc?.value,
            co2EmissionsGPerKm: dto.signals?.co2EmissionsGPerKm,
            latestOdometerMiles: dto.signals?.latestOdometerMiles,
            taxStatus: nonEmpty(dto.signals?.taxStatus),
            taxDueDate: parseDate(dto.signals?.taxDueDate),
            motStatus: nonEmpty(dto.signals?.motStatus),
            motExpiryDate: parseDate(dto.signals?.motExpiryDate),
            motDaysRemaining: dto.signals?.motDaysRemaining,
            lastMotResult: nonEmpty(dto.signals?.lastMotResult),
            lastMotDate: parseDate(dto.signals?.lastMotDate),
            firstMotDue: parseDate(dto.signals?.firstMotDue),
            totalMotTests: dto.signals?.totalMotTests,
            motPassRate: dto.signals?.motPassRate,
            imminentMot: dto.signals?.imminentMot,
            markedForExport: dto.signals?.markedForExport,
            ulezCompliant: dto.signals?.ulezCompliant,
            checkedAt: parseDate(dto.checkedAt) ?? parseDate(dto.dataAsOf) ?? Date()
        )
    }

    static func errorBody(from data: Data) -> ZyfyErrorBodyDTO? {
        try? JSONDecoder().decode(ZyfyErrorBodyDTO.self, from: data)
    }

    static func errorMessage(from data: Data) -> String? {
        errorBody(from: data)?.error
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: value) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: value) { return date }

        day.dateFormat = "yyyy-MM"
        return day.date(from: value)
    }
}

struct ZyfyVehicleResponseDTO: Decodable, Equatable {
    var registration: String?
    var make: String?
    var model: String?
    var vehicleType: String?
    var colour: String?
    var fuelType: String?
    var engineCapacityCc: ZyfyFlexibleInt?
    var yearOfManufacture: Int?
    var monthOfFirstRegistration: String?
    var enrichmentPending: Bool?
    var checkedAt: String?
    var dataAsOf: String?
    var signals: ZyfyVehicleSignalsDTO?
}

struct ZyfyVehicleSignalsDTO: Decodable, Equatable {
    var co2EmissionsGPerKm: Double?
    var ulezCompliant: Bool?
    var markedForExport: Bool?
    var taxStatus: String?
    var taxDueDate: String?
    var motStatus: String?
    var motExpiryDate: String?
    var motDaysRemaining: Int?
    var imminentMot: Bool?
    var latestOdometerMiles: Int?
    var motPassRate: Double?
    var totalMotTests: Int?
    var lastMotDate: String?
    var lastMotResult: String?
    var firstMotDue: String?
}

struct ZyfyErrorBodyDTO: Decodable {
    var error: String?
    var code: String?
    var resets: String?
}

struct ZyfyFlexibleInt: Decodable, Equatable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double.rounded())
        } else {
            value = nil
        }
    }
}
