import Foundation
import SwiftData
import XCTest
@testable import loadMate3

@MainActor
final class TripStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(
            "TripStoreTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        container = try ModelContainer(for: LoadMateModelContainer.schema, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testCopyForwardPickerTitleUsesRequestedDefaultLabel() {
        let profile = insertProfile()
        let defaultTrip = Trip(name: "Default", profile: profile)
        let beach = Trip(name: "Beach", profile: profile)

        XCTAssertEqual(
            TripStore.copyForwardPickerTitle(for: defaultTrip),
            "Default from previous loadings"
        )
        XCTAssertEqual(TripStore.copyForwardPickerTitle(for: beach), "Beach")
    }

    func testDefaultLoadingConfigurationMatchesNameCaseInsensitively() {
        let profile = insertProfile()
        let defaultTrip = Trip(name: " default ", sortOrder: 0, profile: profile)
        context.insert(defaultTrip)
        context.insert(Trip(name: "Beach", sortOrder: 1, profile: profile))

        XCTAssertEqual(TripStore.defaultLoadingConfiguration(for: profile)?.id, defaultTrip.id)
    }

    func testNewTripStaysEmptyWhenItemsAreNotCopied() throws {
        let profile = insertProfile()
        let defaultTrip = insertDefaultTrip(on: profile)
        let awning = insertLibraryItem(name: "Awning", weightKg: 28)
        context.insert(TestFixtures.loadedItem(item: awning, quantity: 1, zone: .rear, trip: defaultTrip))

        let created = Trip(name: "Trip X", sortOrder: 1, profile: profile)
        context.insert(created)

        XCTAssertEqual(created.name, "Trip X")
        XCTAssertTrue(created.loadedItemsList.isEmpty)
        XCTAssertEqual(defaultTrip.loadedItemsList.count, 1)
    }

    func testCopyingDefaultItemsPreservesQuantitiesAndZones() throws {
        let profile = insertProfile()
        let defaultTrip = insertDefaultTrip(on: profile)
        let awning = insertLibraryItem(name: "Awning", weightKg: 28)
        let chairs = insertLibraryItem(name: "Chairs", weightKg: 8)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(60)

        context.insert(
            LoadedItem(item: awning, quantity: 1, zone: .rear, loadedAt: earlier, trip: defaultTrip)
        )
        context.insert(
            LoadedItem(item: chairs, quantity: 2, zone: .frontLocker, loadedAt: later, trip: defaultTrip)
        )
        context.insert(Trip(name: "Beach", sortOrder: 1, profile: profile))

        let created = Trip(name: "Trip X", sortOrder: 2, profile: profile)
        context.insert(created)
        TripStore.copyLoadedItems(from: defaultTrip, to: created, in: context)

        let copied = created.loadedItemsList.sorted { $0.loadedAt < $1.loadedAt }
        let sourceItems = defaultTrip.loadedItemsList

        XCTAssertEqual(sourceItems.count, 2)
        XCTAssertEqual(copied.count, 2)
        XCTAssertEqual(copied.map { $0.item?.name }, ["Awning", "Chairs"])
        XCTAssertEqual(copied.map(\.quantity), [1, 2])
        XCTAssertEqual(copied.map(\.zone), [.rear, .frontLocker])
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: Set(sourceItems.map(\.id))))
        XCTAssertEqual(copied[0].item?.id, awning.id)
        XCTAssertEqual(copied[1].item?.id, chairs.id)
    }

    func testCopyLoadedItemsSkipsRowsWithoutALibraryItem() throws {
        let profile = insertProfile()
        let defaultTrip = insertDefaultTrip(on: profile)
        let awning = insertLibraryItem(name: "Awning", weightKg: 28)
        context.insert(TestFixtures.loadedItem(item: awning, quantity: 1, zone: .middle, trip: defaultTrip))

        let orphan = LoadedItem(item: awning, quantity: 1, zone: .rear, trip: defaultTrip)
        context.insert(orphan)
        orphan.item = nil

        let created = Trip(name: "Trip X", sortOrder: 1, profile: profile)
        context.insert(created)
        TripStore.copyLoadedItems(from: defaultTrip, to: created, in: context)

        XCTAssertEqual(created.loadedItemsList.count, 1)
        XCTAssertEqual(created.loadedItemsList.first?.item?.id, awning.id)
        XCTAssertEqual(created.loadedItemsList.first?.zone, .middle)
    }

    func testCopyLoadedItemsDoesNotCopyATripOntoItself() throws {
        let profile = insertProfile()
        let defaultTrip = insertDefaultTrip(on: profile)
        let awning = insertLibraryItem(name: "Awning", weightKg: 28)
        context.insert(TestFixtures.loadedItem(item: awning, quantity: 1, zone: .front, trip: defaultTrip))

        TripStore.copyLoadedItems(from: defaultTrip, to: defaultTrip, in: context)

        XCTAssertEqual(defaultTrip.loadedItemsList.count, 1)
    }

    private func insertProfile() -> VehicleProfile {
        let profile = TestFixtures.caravanProfile()
        context.insert(profile)
        return profile
    }

    private func insertDefaultTrip(on profile: VehicleProfile) -> Trip {
        let trip = Trip(name: TripStore.defaultTripName, sortOrder: 0, profile: profile)
        context.insert(trip)
        profile.activeTripID = trip.id
        return trip
    }

    private func insertLibraryItem(name: String, weightKg: Double) -> loadMate3.LibraryItem {
        let item = TestFixtures.libraryItem(name: name, weightKg: weightKg)
        context.insert(item)
        return item
    }
}
