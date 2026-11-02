import XCTest
@testable import loadMate3

@MainActor
final class VehicleLookupTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testNormalisationStripsSpacesAndUppercases() {
        XCTAssertEqual(UKRegistration.normalizeForLookup(" ab12 cde "), "AB12CDE")
        XCTAssertEqual(UKRegistration.normalizeForLookup("ab-12-cde"), "AB12CDE")
        XCTAssertEqual(UKRegistration.normalizeForLookup("\txy21zzz\n"), "XY21ZZZ")
    }

    func testDisplayFormatUsesReadableUKSpacing() {
        XCTAssertEqual(UKRegistration.displayFormatted("ab12cde"), "AB12 CDE")
        XCTAssertEqual(UKRegistration.displayFormatted("AB12 CDE"), "AB12 CDE")
        XCTAssertEqual(UKRegistration.displayFormatted("IGI1234"), "IGI 1234")
        XCTAssertEqual(UKRegistration.displayFormatted("A123BCD"), "A123 BCD")
        XCTAssertEqual(UKRegistration.displayFormatted("ABC123A"), "ABC 123A")
    }

    func testPlausibleRegistrationRejectsJunk() {
        XCTAssertTrue(UKRegistration.isPlausible("AB12 CDE"))
        XCTAssertTrue(UKRegistration.isPlausible("A1"))
        XCTAssertFalse(UKRegistration.isPlausible(""))
        XCTAssertFalse(UKRegistration.isPlausible("A"))
        XCTAssertFalse(UKRegistration.isPlausible("123456"))
        XCTAssertFalse(UKRegistration.isPlausible("THISISWAYTOOLONG"))
    }

    func testLikelyCompletePlateRejectsFragments() {
        XCTAssertTrue(UKRegistration.isLikelyCompletePlate("AB12 CDE"))
        XCTAssertTrue(UKRegistration.isLikelyCompletePlate("A123BCD"))
        XCTAssertFalse(UKRegistration.isLikelyCompletePlate("AB12"))
        XCTAssertFalse(UKRegistration.isLikelyCompletePlate("CDE"))
        XCTAssertFalse(UKRegistration.isLikelyCompletePlate("HELLO"))
    }

    func testFacadeRejectsInvalidRegistrationWithoutCallingProvider() async {
        let stub = StubVehicleLookupProvider(result: Self.sampleResult())
        let service = VehicleLookupService(provider: stub)

        do {
            _ = try await service.lookup(registration: "!!!", forceRefresh: false)
            XCTFail("Expected invalid registration")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .invalidRegistration)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(stub.lookupCount, 0)
    }

    func testCacheReturnsPreviousResultWithinTTL() async throws {
        let stub = StubVehicleLookupProvider(result: Self.sampleResult(make: "FORD"))
        var now = Date(timeIntervalSince1970: 1_000_000)
        let service = VehicleLookupService(provider: stub, cacheTTL: 24 * 60 * 60, now: { now })

        let first = try await service.lookup(registration: "AB12 CDE", forceRefresh: false)
        stub.result = Self.sampleResult(make: "VAUXHALL")
        now = now.addingTimeInterval(60 * 60)
        let second = try await service.lookup(registration: "ab12cde", forceRefresh: false)

        XCTAssertEqual(first.make, "FORD")
        XCTAssertEqual(second.make, "FORD")
        XCTAssertEqual(stub.lookupCount, 1)
    }

    func testForceRefreshBypassesCache() async throws {
        let stub = StubVehicleLookupProvider(result: Self.sampleResult(make: "FORD"))
        let service = VehicleLookupService(provider: stub, cacheTTL: 24 * 60 * 60)

        _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
        stub.result = Self.sampleResult(make: "VAUXHALL")
        let refreshed = try await service.lookup(registration: "AB12CDE", forceRefresh: true)

        XCTAssertEqual(refreshed.make, "VAUXHALL")
        XCTAssertEqual(stub.lookupCount, 2)
    }

    func testExpiredCacheMissesAfterTTL() async throws {
        let stub = StubVehicleLookupProvider(result: Self.sampleResult(make: "FORD"))
        var now = Date(timeIntervalSince1970: 1_000_000)
        let service = VehicleLookupService(provider: stub, cacheTTL: 24 * 60 * 60, now: { now })

        _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
        stub.result = Self.sampleResult(make: "PEUGEOT")
        now = now.addingTimeInterval(24 * 60 * 60 + 1)
        let later = try await service.lookup(registration: "AB12CDE", forceRefresh: false)

        XCTAssertEqual(later.make, "PEUGEOT")
        XCTAssertEqual(stub.lookupCount, 2)
    }

    func testDecodeAndMapSuccessfulZyfyResponse() throws {
        let data = Self.successfulZyfyJSON.data(using: .utf8)!
        let dto = try ZyfyVehicleLookupMapper.decodeResponse(data)
        let result = ZyfyVehicleLookupMapper.map(dto, fallbackRegistration: "AB12CDE")

        XCTAssertEqual(dto.make, "VOLKSWAGEN")
        XCTAssertEqual(dto.signals?.motStatus, "valid")
        XCTAssertEqual(result.registration, "AB12CDE")
        XCTAssertEqual(result.displayRegistration, "AB12 CDE")
        XCTAssertEqual(result.make, "VOLKSWAGEN")
        XCTAssertEqual(result.model, "TRANSPORTER")
        XCTAssertEqual(result.colour, "WHITE")
        XCTAssertEqual(result.fuelType, "diesel")
        XCTAssertEqual(result.vehicleType, "van")
        XCTAssertEqual(result.yearOfManufacture, 2012)
        XCTAssertEqual(result.monthOfFirstRegistration, "2012-03")
        XCTAssertEqual(result.firstRegistrationYear, 2012)
        XCTAssertEqual(result.engineCapacityCc, 1968)
        XCTAssertEqual(result.co2EmissionsGPerKm, 198)
        XCTAssertEqual(result.latestOdometerMiles, 84210)
        XCTAssertEqual(result.taxStatus, "Taxed")
        XCTAssertEqual(result.motStatus, "valid")
        XCTAssertEqual(result.motDaysRemaining, 93)
        XCTAssertEqual(result.lastMotResult, "PASSED")
        XCTAssertEqual(result.totalMotTests, 8)
        XCTAssertEqual(result.motPassRate, 0.875)
        XCTAssertEqual(result.imminentMot, false)
        XCTAssertEqual(result.markedForExport, false)
        XCTAssertEqual(result.ulezCompliant, false)
        XCTAssertEqual(result.checkedAt, Self.isoDate("2026-08-13T12:40:00Z"))
        XCTAssertEqual(result.motExpiryDate, Self.dayDate("2026-11-14"))
        XCTAssertEqual(result.taxDueDate, Self.dayDate("2026-09-01"))
        XCTAssertEqual(result.lastMotDate, Self.dayDate("2025-11-14"))
        XCTAssertEqual(result.firstMotDue, Self.dayDate("2015-03-01"))
    }

    func testFirstRegistrationYearFallsBackToManufactureYear() {
        var result = Self.sampleResult()
        result.monthOfFirstRegistration = nil
        result.yearOfManufacture = 2018
        XCTAssertEqual(result.firstRegistrationYear, 2018)

        result.monthOfFirstRegistration = "2012-03"
        XCTAssertEqual(result.firstRegistrationYear, 2012)
    }

    func testLastMOTCaptionShowsDateWhenCurrent() {
        let lastMOT = Self.dayDate("2025-11-14")
        let expiry = Self.dayDate("2026-11-14")
        let now = Self.dayDate("2026-08-13")

        XCTAssertEqual(
            VehicleLookupDisplay.lastMOTCaption(lastMotDate: lastMOT, motExpiryDate: expiry, now: now),
            Formatters.date(lastMOT)
        )
    }

    func testLastMOTCaptionSaysDueWhenExpired() {
        let lastMOT = Self.dayDate("2024-06-01")
        let expiry = Self.dayDate("2025-06-01")
        let now = Self.dayDate("2026-08-13")

        XCTAssertEqual(
            VehicleLookupDisplay.lastMOTCaption(lastMotDate: lastMOT, motExpiryDate: expiry, now: now),
            "MOT due"
        )
    }

    func testLastMOTCaptionAssumesOneYearIfExpiryMissing() {
        let lastMOT = Self.dayDate("2024-06-01")
        let now = Self.dayDate("2026-08-13")

        XCTAssertEqual(
            VehicleLookupDisplay.lastMOTCaption(lastMotDate: lastMOT, motExpiryDate: nil, now: now),
            "MOT due"
        )

        let recent = Self.dayDate("2026-01-15")
        XCTAssertEqual(
            VehicleLookupDisplay.lastMOTCaption(lastMotDate: recent, motExpiryDate: nil, now: now),
            Formatters.date(recent)
        )
    }

    func testIdentityLineJoinsMakeAndModel() {
        XCTAssertEqual(
            VehicleLookupDisplay.identityLine(manufacturer: "Bailey", modelName: "Autograph 79-4F"),
            "Bailey Autograph 79-4F"
        )
        XCTAssertEqual(VehicleLookupDisplay.identityLine(manufacturer: "Bailey", modelName: ""), "Bailey")
        XCTAssertNil(VehicleLookupDisplay.identityLine(manufacturer: "  ", modelName: ""))
    }

    func testZyfyLookupSuccessUsesMockedSession() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            XCTAssertEqual(request.url?.host, "api.lyneqo.com")
            XCTAssertEqual(request.url?.path, "/v1/vehicle")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "registration", value: "AB12CDE")]
            )
            return (Self.http(200), Data(Self.successfulZyfyJSON.utf8))
        }

        let service = ZyfyVehicleLookupService(session: Self.mockSession())
        let result = try await service.lookup(registration: "AB12 CDE", forceRefresh: false)

        XCTAssertEqual(result.make, "VOLKSWAGEN")
        XCTAssertEqual(result.motStatus, "valid")
    }

    func testZyfyInvalidRegistrationMapsToDomainError() async {
        MockURLProtocol.requestHandler = { _ in
            let body = #"{"error":"Registration plate missing or malformed."}"#
            return (Self.http(400), Data(body.utf8))
        }

        let service = ZyfyVehicleLookupService(session: Self.mockSession())
        do {
            _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
            XCTFail("Expected invalid registration")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .invalidRegistration)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testZyfyNotFoundMapsToDomainError() async {
        MockURLProtocol.requestHandler = { _ in
            let body = #"{"error":"not_found"}"#
            return (Self.http(404), Data(body.utf8))
        }

        let service = ZyfyVehicleLookupService(session: Self.mockSession())
        do {
            _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
            XCTFail("Expected not found")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testQuotaExhaustedErrorDescription() {
        XCTAssertEqual(
            VehicleLookupError.quotaExhausted.errorDescription,
            "Lyneqo is a free application. Unfortunately, we've run out of credits this month. Credits reset on the 13th of each month. Lyneqo uses ZyFy.uk — visit that site as an individual user to look up the same vehicle data."
        )
    }

    func testZyfyQuotaExhaustedMapsToDomainErrorWithoutRetry() async {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            let body = #"{"error":"Monthly quota exhausted","code":"quota_exhausted","resets":"2026-09-01T00:00:00Z"}"#
            return (Self.http(429), Data(body.utf8))
        }

        let service = ZyfyVehicleLookupService(session: Self.mockSession())
        do {
            _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
            XCTFail("Expected quota exhausted")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .quotaExhausted)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testZyfyQuotaExhaustedFromZeroRemainingHeader() async {
        MockURLProtocol.requestHandler = { _ in
            return (
                Self.http(429, headers: ["X-Quota-Remaining": "0", "Retry-After": "5"]),
                Data(#"{"error":"Too many requests"}"#.utf8)
            )
        }

        let service = ZyfyVehicleLookupService(session: Self.mockSession())
        do {
            _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
            XCTFail("Expected quota exhausted")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .quotaExhausted)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testZyfyRateLimitRetriesThenMapsToDomainError() async {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return (
                Self.http(429, headers: ["Retry-After": "1"]),
                Data(#"{"error":"Rate limit exceeded"}"#.utf8)
            )
        }

        let service = ZyfyVehicleLookupService(
            session: Self.mockSession(),
            maxRetryAfterSeconds: 0
        )
        do {
            _ = try await service.lookup(registration: "AB12CDE", forceRefresh: false)
            XCTFail("Expected rate limited")
        } catch let error as VehicleLookupError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(requestCount, 3)
    }

    func testRealHX13FKEFixtureMapsSwiftLifestyleBaseVehicle() throws {
        let result = try Self.result(fromFixture: "zyfy-HX13FKE")

        XCTAssertEqual(result.registration, "HX13FKE")
        XCTAssertEqual(result.displayRegistration, "HX13 FKE")
        XCTAssertEqual(result.make, "FIAT")
        XCTAssertEqual(result.model, "DUCATO")
        XCTAssertEqual(result.firstRegistrationYear, 2013)
        XCTAssertEqual(result.yearOfManufacture, 2013)
        XCTAssertEqual(result.monthOfFirstRegistration, "2013-05")
        XCTAssertEqual(result.fuelType, "diesel")
        XCTAssertEqual(result.engineCapacityCc, 2287)
        XCTAssertEqual(result.motStatus, "valid")
        XCTAssertEqual(result.lastMotResult?.lowercased(), "passed")
        XCTAssertEqual(result.lastMotDate, Self.dayDate("2026-03-25"))
        XCTAssertEqual(result.motExpiryDate, Self.dayDate("2027-03-24"))
        XCTAssertEqual(
            VehicleLookupDisplay.lastMOTCaption(
                lastMotDate: result.lastMotDate,
                motExpiryDate: result.motExpiryDate,
                now: Self.dayDate("2026-08-13")
            ),
            Formatters.date(result.lastMotDate)
        )
    }

    func testRealWA18ZVXFixtureMapsAutoTrailBaseVehicle() throws {
        let result = try Self.result(fromFixture: "zyfy-WA18ZVX")

        XCTAssertEqual(result.registration, "WA18ZVX")
        XCTAssertEqual(result.displayRegistration, "WA18 ZVX")
        XCTAssertEqual(result.make, "FIAT")
        XCTAssertEqual(result.model, "AUTO TRAIL")
        XCTAssertEqual(result.firstRegistrationYear, 2018)
        XCTAssertEqual(result.yearOfManufacture, 2018)
        XCTAssertEqual(result.monthOfFirstRegistration, "2018-04")
        XCTAssertEqual(result.fuelType, "diesel")
        XCTAssertEqual(result.motStatus, "valid")
        XCTAssertEqual(result.lastMotDate, Self.dayDate("2026-03-30"))
        XCTAssertEqual(result.motExpiryDate, Self.dayDate("2027-04-03"))
        XCTAssertEqual(result.ulezCompliant, true)
    }

    private static func result(fromFixture name: String) throws -> VehicleLookupResult {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let dto = try ZyfyVehicleLookupMapper.decodeResponse(data)
        return ZyfyVehicleLookupMapper.map(dto, fallbackRegistration: name)
    }

    private static func sampleResult(make: String = "FORD") -> VehicleLookupResult {
        VehicleLookupResult(
            registration: "AB12CDE",
            displayRegistration: "AB12 CDE",
            make: make,
            model: "TRANSIT",
            colour: "WHITE",
            fuelType: "diesel",
            vehicleType: "van",
            yearOfManufacture: 2018,
            monthOfFirstRegistration: "2018-01",
            engineCapacityCc: 1995,
            co2EmissionsGPerKm: 180,
            latestOdometerMiles: 50000,
            taxStatus: "Taxed",
            taxDueDate: dayDate("2026-09-01"),
            motStatus: "valid",
            motExpiryDate: dayDate("2026-11-14"),
            motDaysRemaining: 90,
            lastMotResult: "PASSED",
            lastMotDate: dayDate("2025-11-14"),
            firstMotDue: dayDate("2021-01-01"),
            totalMotTests: 4,
            motPassRate: 1,
            imminentMot: false,
            markedForExport: false,
            ulezCompliant: false,
            checkedAt: isoDate("2026-08-13T12:40:00Z")
        )
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        var fields = ["Content-Type": "application/json"]
        headers.forEach { fields[$0.key] = $0.value }
        return HTTPURLResponse(
            url: URL(string: "https://api.lyneqo.com/v1/vehicle?registration=AB12CDE")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!
    }

    private static func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private static func dayDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private static let successfulZyfyJSON = """
    {
      "registration": "AB12CDE",
      "make": "VOLKSWAGEN",
      "model": "TRANSPORTER",
      "vehicleType": "van",
      "colour": "WHITE",
      "fuelType": "diesel",
      "engineCapacityCc": 1968,
      "yearOfManufacture": 2012,
      "monthOfFirstRegistration": "2012-03",
      "enrichmentPending": false,
      "checkedAt": "2026-08-13T12:40:00Z",
      "dataAsOf": "2026-08-13T12:00:00Z",
      "signals": {
        "co2EmissionsGPerKm": 198,
        "ulezCompliant": false,
        "markedForExport": false,
        "taxStatus": "Taxed",
        "taxDueDate": "2026-09-01",
        "motStatus": "valid",
        "motExpiryDate": "2026-11-14",
        "motDaysRemaining": 93,
        "imminentMot": false,
        "latestOdometerMiles": 84210,
        "motPassRate": 0.875,
        "totalMotTests": 8,
        "lastMotDate": "2025-11-14",
        "lastMotResult": "PASSED",
        "firstMotDue": "2015-03-01"
      }
    }
    """
}

final class StubVehicleLookupProvider: VehicleLookupProviding, @unchecked Sendable {
    var lookupCount = 0
    var result: VehicleLookupResult
    var error: Error?

    init(result: VehicleLookupResult, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func lookup(registration: String, forceRefresh: Bool) async throws -> VehicleLookupResult {
        lookupCount += 1
        if let error { throw error }
        return result
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
