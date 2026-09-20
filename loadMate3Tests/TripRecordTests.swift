import Foundation
import SwiftData
import XCTest
@testable import loadMate3

@MainActor
final class TripRecordTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try LoadMateModelContainer.makePreview()
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testCreateAndReopenTripRecord() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Scotland"
        draft.notes = "First tour"
        draft.stops = [TripStopDraft(locationName: "Cambridge")]

        let saved = try TripRecordStore.save(draft, in: context)
        let reopened = try refetchRecord(id: saved.id)

        XCTAssertEqual(reopened.name, "Scotland")
        XCTAssertEqual(reopened.notes, "First tour")
        XCTAssertEqual(reopened.vehicleProfileID, profile.id)
        XCTAssertEqual(reopened.stopsList.map(\.locationName), ["Cambridge"])
    }

    func testEditAndResaveTripRecord() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Scotland"
        let saved = try TripRecordStore.save(draft, in: context)

        var edited = TripRecordDraft.from(saved)
        edited.name = "Highlands"
        edited.notes = "Updated"
        _ = try TripRecordStore.save(edited, in: context)

        let reopened = try refetchRecord(id: saved.id)
        XCTAssertEqual(reopened.name, "Highlands")
        XCTAssertEqual(reopened.notes, "Updated")
    }

    func testDeleteTripRecord() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Scotland"
        let saved = try TripRecordStore.save(draft, in: context)
        let id = saved.id

        TripRecordStore.delete(saved, in: context)

        XCTAssertNil(TripRecordStore.fetchRecord(id: id, in: context))
    }

    func testOneStopPersists() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Cambridge weekend"
        draft.stops = [TripStopDraft(locationName: "Cambridge", notes: "University site")]

        let saved = try TripRecordStore.save(draft, in: context)
        let reopened = try refetchRecord(id: saved.id)
        XCTAssertEqual(reopened.stopsList.count, 1)
        XCTAssertEqual(reopened.stopsList.first?.locationName, "Cambridge")
        XCTAssertEqual(reopened.stopsList.first?.notes, "University site")
    }

    func testMultipleStopsAndOrderingAfterRelaunch() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "North"
        draft.stops = [
            TripStopDraft(locationName: "Cambridge"),
            TripStopDraft(locationName: "York"),
            TripStopDraft(locationName: "Edinburgh")
        ]

        let saved = try TripRecordStore.save(draft, in: context)
        var edited = TripRecordDraft.from(saved)
        edited.stops.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        _ = try TripRecordStore.save(edited, in: context)

        let reopened = try refetchRecord(id: saved.id)
        XCTAssertEqual(reopened.stopsList.map(\.locationName), ["York", "Edinburgh", "Cambridge"])
        XCTAssertEqual(reopened.stopsList.map(\.sortOrder), [0, 1, 2])
    }

    func testJourneyOnlyTripPersistsWithoutStay() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Spain"
        draft.originName = "Home"
        draft.legs = [TripLegDraft(fromName: "Home", toName: "Spain", mileageText: "1200")]
        XCTAssertTrue(TripRecordDraft.validate(draft).isEmpty)

        let saved = try TripRecordStore.save(draft, in: context)
        let reopened = try refetchRecord(id: saved.id)
        XCTAssertEqual(reopened.stopsList.count, 0)
        XCTAssertEqual(reopened.legsList.count, 1)
        XCTAssertEqual(reopened.legsList.first?.fromName, "Home")
        XCTAssertEqual(reopened.legsList.first?.toName, "Spain")
    }

    func testLegOrderingAfterRelaunch() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "North"
        draft.legs = [
            TripLegDraft(fromName: "Home", toName: "Cambridge", mileageText: "60"),
            TripLegDraft(fromName: "Cambridge", toName: "York", mileageText: "150")
        ]
        XCTAssertTrue(TripRecordDraft.validate(draft).isEmpty)

        let saved = try TripRecordStore.save(draft, in: context)
        var edited = TripRecordDraft.from(saved)
        edited.legs.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        _ = try TripRecordStore.save(edited, in: context)

        let reopened = try refetchRecord(id: saved.id)
        XCTAssertEqual(reopened.legsList.map(\.fromName), ["Cambridge", "York"])
        XCTAssertEqual(reopened.legsList.map(\.toName), ["York", "Cambridge"])
        XCTAssertEqual(reopened.legsList.map(\.sortOrder), [0, 1])
    }

    func testMileageTotalIgnoresNilAndKeepsZero() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Mileage"
        draft.legs = [
            TripLegDraft(fromName: "A", toName: "B", mileageText: "10"),
            TripLegDraft(fromName: "B", toName: "C", mileageText: ""),
            TripLegDraft(fromName: "C", toName: "D", mileageText: "0")
        ]

        let saved = try TripRecordStore.save(draft, in: context)
        let totals = TripRecordSupport.totals(for: saved)
        XCTAssertEqual(totals.mileage, 10)
        XCTAssertTrue(totals.hasMileage)
        XCTAssertNil(saved.legsList.first(where: { $0.fromName == "B" })?.mileage)
        XCTAssertEqual(saved.legsList.first(where: { $0.fromName == "C" })?.mileage, 0)
    }

    func testExpenseCategoriesMatchTheShortListAndKeepLegacyFuelOther() {
        XCTAssertEqual(
            TripExpenseCategory.allCases.map(\.displayName),
            ["Fuel", "Site", "Tolls/Road", "Ferry", "Parking", "Food", "Activities", "Other"]
        )
        XCTAssertEqual(TripExpenseCategory.fuel.rawValue, "fuel")
        XCTAssertEqual(TripExpenseCategory.other.rawValue, "other")
        XCTAssertEqual(TripExpenseCategory(rawValue: "fuel"), .fuel)
        XCTAssertNil(TripExpenseCategory.resolved(from: "groceries"))
    }

    func testCostTotalsAndGrandTotal() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Costs"
        var cambridge = TripStopDraft(locationName: "Cambridge")
        cambridge.siteCostText = "32.75"
        var york = TripStopDraft(locationName: "York")
        york.siteCostText = "20"
        draft.stops = [cambridge, york]
        draft.expenses = [
            TripExpenseDraft(category: .fuel, amountText: "40.50"),
            TripExpenseDraft(category: .site, amountText: "5.00"),
            TripExpenseDraft(category: .tollsRoad, amountText: "8.25"),
            TripExpenseDraft(category: .other, amountText: "6.75")
        ]

        let saved = try TripRecordStore.save(draft, in: context)
        let totals = TripRecordSupport.totals(for: saved)
        XCTAssertEqual(totals.siteMinorUnits, 5775)
        XCTAssertEqual(totals.fuelMinorUnits, 4050)
        XCTAssertEqual(totals.expenseMinorUnits[.tollsRoad], 825)
        XCTAssertEqual(totals.otherMinorUnits, 675)
        XCTAssertEqual(totals.grandMinorUnits, 11325)
        XCTAssertEqual(totals.summaryRows.map(\.title), ["Site", "Fuel", "Tolls/Road", "Other"])
    }

    func testNilValuesDistinctFromZeroForMileageAndSiteCost() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Nil vs zero"
        var blankCost = TripStopDraft(locationName: "A")
        blankCost.siteCostText = ""
        var zeroCost = TripStopDraft(locationName: "B")
        zeroCost.siteCostText = "0"
        draft.stops = [blankCost, zeroCost]
        draft.legs = [
            TripLegDraft(fromName: "A", toName: "B", mileageText: ""),
            TripLegDraft(fromName: "B", toName: "C", mileageText: "0")
        ]

        let saved = try TripRecordStore.save(draft, in: context)
        XCTAssertNil(saved.stopsList[0].siteCostMinorUnits)
        XCTAssertEqual(saved.stopsList[1].siteCostMinorUnits, 0)
        XCTAssertNil(saved.legsList[0].mileage)
        XCTAssertEqual(saved.legsList[1].mileage, 0)
    }

    func testRejectsNegativeMileageAndCostsAndInvertedDatesAndBlankName() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.name = "   "
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.blankName))

        draft.name = "Spain"
        draft.legs = [TripLegDraft(toName: "Spain")]
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.blankOrigin))

        draft.originName = "Home"
        draft.legs = []
        draft.name = "Dates"
        draft.startDate = date(2026, 6, 10)
        draft.endDate = date(2026, 6, 1)
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.endBeforeStart))

        draft.endDate = date(2026, 6, 12)
        var stop = TripStopDraft(locationName: "York")
        stop.arrivedAt = date(2026, 6, 10)
        stop.departedAt = date(2026, 6, 9)
        draft.stops = [stop]
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.departureBeforeArrival))

        stop.departedAt = date(2026, 6, 11)
        stop.siteCostText = "-1"
        draft.stops = [stop]
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.negativeSiteCost))

        stop.siteCostText = ""
        draft.stops = [stop]
        draft.legs = [TripLegDraft(fromName: "A", toName: "B", mileageText: "-2")]
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.negativeMileage))

        draft.legs = [TripLegDraft(fromName: "A", toName: "B", mileageText: "10")]
        draft.expenses = [TripExpenseDraft(amountText: "-3")]
        XCTAssertTrue(TripRecordDraft.validate(draft).contains(.negativeExpense))
    }

    func testSameLoadingConfigurationCanBeUsedByMultipleTripRecords() throws {
        let profile = insertProfile()
        let config = TestFixtures.trip(name: "Beach", profile: profile)
        context.insert(config)

        var first = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        first.name = "June"
        first.loadingConfigurationID = config.id
        var second = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        second.name = "August"
        second.loadingConfigurationID = config.id

        let savedFirst = try TripRecordStore.save(first, in: context)
        let savedSecond = try TripRecordStore.save(second, in: context)

        XCTAssertEqual(savedFirst.loadingConfigurationID, config.id)
        XCTAssertEqual(savedSecond.loadingConfigurationID, config.id)
        XCTAssertEqual((try context.fetch(FetchDescriptor<Trip>())).count, 1)
    }

    func testDeletingTripRecordDoesNotDeleteLoadingConfiguration() throws {
        let profile = insertProfile()
        let config = TestFixtures.trip(name: "Beach", profile: profile)
        context.insert(config)
        let item = TestFixtures.libraryItem(name: "Awning", weightKg: 20)
        context.insert(item)
        let loaded = TestFixtures.loadedItem(item: item, zone: .unassigned, trip: config)
        context.insert(loaded)

        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "June"
        draft.loadingConfigurationID = config.id
        let saved = try TripRecordStore.save(draft, in: context)

        TripRecordStore.delete(saved, in: context)

        XCTAssertEqual((try context.fetch(FetchDescriptor<Trip>())).map(\.id), [config.id])
        XCTAssertEqual((try context.fetch(FetchDescriptor<LoadedItem>())).count, 1)
        XCTAssertEqual(item.name, "Awning")
    }

    func testDeletingLoadingConfigurationLeavesTripRecordOpenable() throws {
        let profile = insertProfile()
        let config = TestFixtures.trip(name: "Beach", profile: profile)
        context.insert(config)

        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "June"
        draft.loadingConfigurationID = config.id
        let saved = try TripRecordStore.save(draft, in: context)

        context.delete(config)
        try context.save()

        let reopened = try XCTUnwrap(TripRecordStore.fetchRecord(id: saved.id, in: context))
        XCTAssertEqual(reopened.name, "June")
        XCTAssertEqual(reopened.loadingConfigurationID, config.id)
        let remainingTrips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertNil(TripRecordStore.loadingConfiguration(id: reopened.loadingConfigurationID, from: remainingTrips))
    }

    func testDeletingProfileLeavesHistoricalTripRecord() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Archive"
        let saved = try TripRecordStore.save(draft, in: context)
        let recordID = saved.id
        let profileID = profile.id

        context.delete(profile)
        try context.save()

        let reopened = try XCTUnwrap(TripRecordStore.fetchRecord(id: recordID, in: context))
        XCTAssertEqual(reopened.vehicleProfileID, profileID)
        XCTAssertEqual(reopened.name, "Archive")
        XCTAssertTrue((try context.fetch(FetchDescriptor<VehicleProfile>())).isEmpty)
    }

    func testChildCascadeDeletesStopsLegsAndExpenses() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Cascade"
        draft.stops = [TripStopDraft(locationName: "York")]
        draft.legs = [TripLegDraft(fromName: "Home", toName: "York", mileageText: "40")]
        draft.expenses = [TripExpenseDraft(amountText: "12.00")]
        let saved = try TripRecordStore.save(draft, in: context)

        XCTAssertEqual((try context.fetch(FetchDescriptor<TripStop>())).count, 1)
        XCTAssertEqual((try context.fetch(FetchDescriptor<TripLeg>())).count, 1)
        XCTAssertEqual((try context.fetch(FetchDescriptor<TripExpense>())).count, 1)

        TripRecordStore.delete(saved, in: context)

        XCTAssertEqual((try context.fetch(FetchDescriptor<TripStop>())).count, 0)
        XCTAssertEqual((try context.fetch(FetchDescriptor<TripLeg>())).count, 0)
        XCTAssertEqual((try context.fetch(FetchDescriptor<TripExpense>())).count, 0)
    }

    func testExistingTripLoadedItemsAndActiveTripIDSurviveInsertingTripRecords() throws {
        let profile = insertProfile()
        let beach = TestFixtures.trip(name: "Beach", profile: profile)
        let europe = TestFixtures.trip(name: "Europe", profile: profile)
        context.insert(beach)
        context.insert(europe)
        profile.activeTripID = beach.id
        let item = TestFixtures.libraryItem(name: "Chairs", weightKg: 8)
        context.insert(item)
        let loaded = TestFixtures.loadedItem(item: item, quantity: 2, zone: .unassigned, trip: beach)
        context.insert(loaded)
        try context.save()

        let tripIDs = Set((try context.fetch(FetchDescriptor<Trip>())).map(\.id))
        let loadedCount = try context.fetch(FetchDescriptor<LoadedItem>()).count
        let activeID = profile.activeTripID

        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "History"
        _ = try TripRecordStore.save(draft, in: context)

        XCTAssertEqual(Set((try context.fetch(FetchDescriptor<Trip>())).map(\.id)), tripIDs)
        XCTAssertEqual((try context.fetch(FetchDescriptor<LoadedItem>())).count, loadedCount)
        XCTAssertEqual(profile.activeTripID, activeID)
        XCTAssertEqual(beach.name, "Beach")
        XCTAssertEqual(europe.name, "Europe")
    }

    func testMoneyPersistenceRoundTripsExactAmounts() throws {
        let amounts: [Decimal] = [0, Decimal(string: "0.01")!, Decimal(string: "1.99")!, Decimal(string: "32.75")!, Decimal(string: "999.99")!, Decimal(string: "10000.00")!]
        let expectedMinor: [Int64] = [0, 1, 199, 3275, 99999, 1_000_000]
        let profile = insertProfile()

        for (amount, expected) in zip(amounts, expectedMinor) {
            var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
            draft.name = "Money \(amount)"
            draft.expenses = [TripExpenseDraft(category: .fuel, amountText: NSDecimalNumber(decimal: amount).stringValue)]
            let saved = try TripRecordStore.save(draft, in: context)
            let reopened = try refetchRecord(id: saved.id)
            XCTAssertEqual(reopened.expensesList.first?.amountMinorUnits, expected, "Failed for £\(amount)")
            XCTAssertEqual(
                TripRecordMoney.decimal(fromMinorUnits: expected, currencyCode: "GBP"),
                amount
            )
        }
    }

    func testRouteAddsJourneyWithoutStayThenOptionalStayAndReturn() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.startDate = date(2026, 8, 1)
        draft.endDate = date(2026, 8, 10)
        draft.originName = "Storage"

        TripRecordSupport.appendJourney(to: &draft)
        XCTAssertEqual(draft.legs.count, 1)
        XCTAssertEqual(draft.stops.count, 0)
        XCTAssertEqual(draft.legs[0].fromName, "Storage")
        XCTAssertEqual(
            Calendar.current.startOfDay(for: draft.legs[0].travelledOn),
            Calendar.current.startOfDay(for: date(2026, 8, 1))
        )
        draft.legs[0].toName = "Longleat"
        TripRecordSupport.syncRoutePlaces(in: &draft)

        TripRecordSupport.appendStay(to: &draft)
        XCTAssertEqual(draft.stops.count, 1)
        XCTAssertEqual(draft.stops[0].locationName, "Longleat")

        TripRecordSupport.appendJourney(to: &draft)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: draft.legs[1].travelledOn),
            Calendar.current.startOfDay(for: draft.stops[0].departedAt)
        )
        XCTAssertEqual(draft.legs.count, 2)
        XCTAssertEqual(draft.stops.count, 1)
        XCTAssertEqual(draft.legs[1].fromName, "Longleat")
        draft.legs[1].toName = "Storage"
        TripRecordSupport.syncRoutePlaces(in: &draft)

        XCTAssertEqual(draft.legs.map { "\($0.fromName)|\($0.toName)" }, [
            "Storage|Longleat",
            "Longleat|Storage"
        ])
        XCTAssertEqual(draft.stops.map(\.locationName), ["Longleat"])
    }

    func testDeleteStayLeavesJourneyInPlace() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.name = "York weekend"
        draft.originName = "Home"
        TripRecordSupport.appendJourney(to: &draft)
        draft.legs[0].toName = "York"
        TripRecordSupport.syncRoutePlaces(in: &draft)
        TripRecordSupport.appendStay(to: &draft)

        XCTAssertEqual(draft.legs.count, 1)
        XCTAssertEqual(draft.stops.count, 1)

        TripRecordSupport.deleteStay(in: &draft, id: draft.stops[0].id)

        XCTAssertEqual(draft.legs.count, 1)
        XCTAssertEqual(draft.stops.count, 0)
        XCTAssertEqual(draft.legs[0].fromName, "Home")
        XCTAssertEqual(draft.legs[0].toName, "York")
        XCTAssertTrue(TripRecordDraft.validate(draft).isEmpty)
    }

    func testAppendStayAfterReturnJourneyStillFollowsFirstJourney() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.originName = "Storage"
        TripRecordSupport.appendJourney(to: &draft)
        draft.legs[0].toName = "York"
        TripRecordSupport.syncRoutePlaces(in: &draft)
        TripRecordSupport.appendJourney(to: &draft)
        draft.legs[1].toName = "Storage"
        TripRecordSupport.syncRoutePlaces(in: &draft)

        TripRecordSupport.appendStay(to: &draft)
        XCTAssertEqual(draft.legs.count, 2)
        XCTAssertEqual(draft.stops.count, 1)
        XCTAssertEqual(draft.stops[0].locationName, "York")
        XCTAssertEqual(
            TripRecordSupport.routeCards(from: draft).map(\.id).map { id in
                id.hasPrefix("journey") ? "journey" : "stay"
            },
            ["journey", "stay", "journey"]
        )
    }

    func testMoveRouteReordersDestinationPairsTogether() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.originName = "Home"
        TripRecordSupport.appendJourney(to: &draft)
        draft.legs[0].toName = "York"
        TripRecordSupport.syncRoutePlaces(in: &draft)
        TripRecordSupport.appendStay(to: &draft)
        TripRecordSupport.appendJourney(to: &draft)
        draft.legs[1].toName = "Bath"
        TripRecordSupport.syncRoutePlaces(in: &draft)
        TripRecordSupport.appendStay(to: &draft)

        TripRecordSupport.moveRoute(
            in: &draft,
            from: .destination(0),
            to: .destination(1)
        )
        XCTAssertEqual(draft.stops.map(\.locationName), ["Bath", "York"])
        XCTAssertEqual(draft.legs.map(\.toName), ["Bath", "York"])
    }

    func testSyncRoutePlacesKeepsReorderedFirstJourneyAsOrigin() {
        var draft = TripRecordDraft.blank(vehicleProfileID: UUID(), currencyCode: "GBP")
        draft.originName = "Home"
        draft.legs = [
            TripLegDraft(fromName: "Home", toName: "Cambridge"),
            TripLegDraft(fromName: "Cambridge", toName: "York")
        ]
        TripRecordSupport.syncRoutePlaces(in: &draft)
        draft.legs.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        TripRecordSupport.syncRoutePlaces(in: &draft)

        XCTAssertEqual(draft.originName, "Cambridge")
        XCTAssertEqual(draft.legs.map(\.fromName), ["Cambridge", "York"])
        XCTAssertEqual(draft.legs.map(\.toName), ["York", "Cambridge"])
    }

    func testTravelTimeParsesHoursAndMinutesAndTotals() throws {
        XCTAssertEqual(TripRecordDraft.parseTravelMinutes("2:30"), 150)
        XCTAssertEqual(TripRecordDraft.parseTravelMinutes("2.5"), 150)
        XCTAssertEqual(TripRecordDraft.parseTravelMinutes("0:45"), 45)
        XCTAssertNil(TripRecordDraft.parseTravelMinutes("abc"))

        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Timed"
        draft.legs = [
            TripLegDraft(fromName: "A", toName: "B", travelTimeText: "2:30"),
            TripLegDraft(fromName: "B", toName: "C", travelTimeText: "2.5"),
            TripLegDraft(fromName: "C", toName: "D", travelTimeText: "")
        ]
        let saved = try TripRecordStore.save(draft, in: context)
        XCTAssertEqual(saved.legsList[0].travelMinutes, 150)
        XCTAssertEqual(saved.legsList[1].travelMinutes, 150)
        XCTAssertNil(saved.legsList[2].travelMinutes)
        let totals = TripRecordSupport.totals(for: saved)
        XCTAssertEqual(totals.travelMinutes, 300)
        XCTAssertTrue(totals.hasTravelTime)
        XCTAssertEqual(TripRecordSupport.travelTimeText(150), "2 hr 30 min")
    }

    func testTimelineSortsOldestTripFirst() throws {
        let profile = insertProfile()
        var later = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        later.name = "Edinburgh"
        later.startDate = date(2026, 8, 1)
        var earlier = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        earlier.name = "Cambridge"
        earlier.startDate = date(2026, 6, 1)
        _ = try TripRecordStore.save(later, in: context)
        _ = try TripRecordStore.save(earlier, in: context)

        let records = try context.fetch(FetchDescriptor<TripRecord>())
        XCTAssertEqual(
            TripRecordSupport.timelineSorted(records).map(\.name),
            ["Cambridge", "Edinburgh"]
        )
    }

    func testAnnualCostsSummariseRecordedTripCostsByYear() throws {
        let profile = insertProfile()
        var current = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        current.name = "June"
        current.startDate = date(2026, 6, 1)
        current.expenses = [TripExpenseDraft(category: .fuel, amountText: "10.00")]
        var later = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        later.name = "August"
        later.startDate = date(2026, 8, 1)
        later.expenses = [TripExpenseDraft(category: .food, amountText: "5.50")]
        var empty = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        empty.name = "No costs"
        empty.startDate = date(2026, 7, 1)
        _ = try TripRecordStore.save(current, in: context)
        _ = try TripRecordStore.save(later, in: context)
        _ = try TripRecordStore.save(empty, in: context)

        let years = TripRecordSupport.annualCosts(for: try context.fetch(FetchDescriptor<TripRecord>()))
        XCTAssertEqual(years.count, 1)
        XCTAssertEqual(years.first?.year, 2026)
        XCTAssertEqual(years.first?.totalMinorUnits, 1550)
        XCTAssertEqual(years.first?.itemCount, 2)
        XCTAssertEqual(years.first?.detail, "2 costs")
    }

    func testListClassificationKeepsOpenEndedPastTripCurrent() {
        let now = date(2026, 8, 28)
        XCTAssertEqual(
            TripRecordSupport.phase(startDate: date(2026, 9, 1), endDate: nil, now: now),
            .upcoming
        )
        XCTAssertEqual(
            TripRecordSupport.phase(startDate: date(2026, 8, 20), endDate: date(2026, 8, 30), now: now),
            .current
        )
        XCTAssertEqual(
            TripRecordSupport.phase(startDate: date(2026, 8, 1), endDate: date(2026, 8, 10), now: now),
            .completed
        )
        XCTAssertEqual(
            TripRecordSupport.phase(startDate: date(2026, 7, 1), endDate: nil, now: now),
            .current
        )
    }

    func testSchemaIncludesTripRecordTypesAndIsolationSchemasOmitThem() {
        let names = Set(LoadMateModelContainer.schema.entities.compactMap(\.name))
        XCTAssertTrue(names.isSuperset(of: ["TripRecord", "TripStop", "TripLeg", "TripExpense", "Trip"]))
        XCTAssertFalse(LoadMateModelContainer.coreVehicleIsolationSchema.entities.map(\.name).contains("TripRecord"))
    }

    func testCancelDraftDoesNotInsertRecords() throws {
        let profile = insertProfile()
        var draft = TripRecordDraft.blank(vehicleProfileID: profile.id, currencyCode: "GBP")
        draft.name = "Unsaved"
        draft.stops = [TripStopDraft(locationName: "York")]

        XCTAssertEqual((try context.fetch(FetchDescriptor<TripRecord>())).count, 0)
        XCTAssertEqual((try context.fetch(FetchDescriptor<TripStop>())).count, 0)
        XCTAssertTrue(TripRecordDraft.validate(draft).isEmpty)
    }

    private func insertProfile() -> VehicleProfile {
        let profile = TestFixtures.caravanProfile()
        context.insert(profile)
        return profile
    }

    private func refetchRecord(id: UUID) throws -> TripRecord {
        let fresh = ModelContext(container)
        let all = try fresh.fetch(FetchDescriptor<TripRecord>())
        return try XCTUnwrap(all.first { $0.id == id })
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}
