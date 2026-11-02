import XCTest
@testable import loadMate3

/// Optional live lookups through the Lyneqo proxy. Skipped unless `ZYFY_LIVE_TESTS=1`.
///
/// Known motorhome plates for occasional checks (DVLA make/model is the base vehicle):
/// - HX13 FKE — Swift Lifestyle 686 (2013), DVLA: FIAT DUCATO
/// - WA18 ZVX — Auto-Trail Frontier Scout (2018), DVLA: FIAT AUTO TRAIL
/// - BX65 JWW — Chausson / Fiat Ducato (2015/16)
/// - HX15 FFW — Swift / Fiat Ducato (2015)
/// - WA67 ZKN — Auto-Trail / Fiat Ducato (2017/18)
/// - KX65 CEO — Auto-Trail Tracker RB (2015)
@MainActor
final class VehicleLookupLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ZYFY_LIVE_TESTS"] == "1",
            "Set ZYFY_LIVE_TESTS=1 to run live lookups through the Lyneqo proxy (uses monthly quota)."
        )
    }

    func testLiveHX13FKEIsFiatDucato2013() async throws {
        let result = try await liveLookup("HX13 FKE")

        XCTAssertEqual(result.registration, "HX13FKE")
        XCTAssertEqual(result.make?.uppercased(), "FIAT")
        XCTAssertEqual(result.model?.uppercased(), "DUCATO")
        XCTAssertEqual(result.firstRegistrationYear, 2013)
        XCTAssertNotNil(result.motStatus)
        XCTAssertNotNil(result.lastMotDate ?? result.motExpiryDate)
    }

    func testLiveWA18ZVXIsFiatAutoTrail2018() async throws {
        let result = try await liveLookup("WA18 ZVX")

        XCTAssertEqual(result.registration, "WA18ZVX")
        XCTAssertEqual(result.make?.uppercased(), "FIAT")
        XCTAssertTrue(result.model?.uppercased().contains("TRAIL") == true)
        XCTAssertEqual(result.firstRegistrationYear, 2018)
        XCTAssertNotNil(result.motStatus)
        XCTAssertNotNil(result.lastMotDate ?? result.motExpiryDate)
    }

    private func liveLookup(_ registration: String) async throws -> VehicleLookupResult {
        let service = VehicleLookupService(
            provider: ZyfyVehicleLookupService(session: .shared),
            cacheTTL: 0
        )
        return try await service.lookup(registration: registration, forceRefresh: true)
    }
}
