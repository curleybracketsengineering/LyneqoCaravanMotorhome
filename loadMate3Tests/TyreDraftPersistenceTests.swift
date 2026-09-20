import SwiftData
import UIKit
import XCTest
@testable import loadMate3

@MainActor
final class TyreStoreEditorDetailsTests: XCTestCase {
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

    func testApplyEditorDetailsPersistsTypedFields() {
        let record = makeRecord()
        record.dateCode = "1221"

        let result = TyreStore.applyEditorDetails(
            to: record,
            manufacturer: " Michelin ",
            modelName: "Agilis",
            tyreSize: "225/75 R16",
            loadIndex: "121",
            speedRating: "R",
            dateCode: "1221",
            recommendedPressureDisplay: "65",
            latestPressureDisplay: "62",
            latestPressureDate: Date(timeIntervalSince1970: 1_700_000_000),
            notes: " Check weekly ",
            installedDate: Date(timeIntervalSince1970: 1_600_000_000),
            removedDate: Date(),
            isCurrentlyFitted: true,
            pressureUnit: .psi,
            requireValidDateCode: false,
            in: context
        )

        XCTAssertEqual(result, .saved)
        XCTAssertEqual(record.manufacturer, "Michelin")
        XCTAssertEqual(record.modelName, "Agilis")
        XCTAssertEqual(record.tyreSize, "225/75 R16")
        XCTAssertEqual(record.loadIndex, "121")
        XCTAssertEqual(record.speedRating, "R")
        XCTAssertEqual(record.dateCode, "1221")
        XCTAssertEqual(record.recommendedPressurePSI, 65)
        XCTAssertEqual(record.latestPressurePSI, 62)
        XCTAssertEqual(record.notes, "Check weekly")
        XCTAssertTrue(record.isCurrentlyFitted)
        XCTAssertNil(record.removedDate)
    }

    func testInvalidDateCodeDoesNotSaveWhenRequired() {
        let record = makeRecord()
        record.manufacturer = "Original"

        let result = TyreStore.applyEditorDetails(
            to: record,
            manufacturer: "Changed",
            modelName: "",
            tyreSize: "",
            loadIndex: "",
            speedRating: "",
            dateCode: "9999",
            recommendedPressureDisplay: "",
            latestPressureDisplay: "",
            latestPressureDate: Date(),
            notes: "",
            installedDate: Date(),
            removedDate: Date(),
            isCurrentlyFitted: true,
            pressureUnit: .psi,
            requireValidDateCode: true,
            in: context
        )

        XCTAssertEqual(result, .blockedByInvalidDateCode)
        XCTAssertEqual(record.manufacturer, "Original")
    }

    func testInvalidDateCodeKeepsExistingCodeWhenNotRequired() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 8))!
        let parsed = TyreSupport.parseDateCode("1221", now: now)
        let record = makeRecord()
        record.manufacturer = "Original"
        record.dateCode = parsed?.normalized ?? "1221"
        record.manufactureWeek = parsed?.week
        record.manufactureYear = parsed?.year
        record.manufactureDate = parsed?.manufactureDate

        let result = TyreStore.applyEditorDetails(
            to: record,
            manufacturer: "Updated",
            modelName: "",
            tyreSize: "",
            loadIndex: "",
            speedRating: "",
            dateCode: "12",
            recommendedPressureDisplay: "58",
            latestPressureDisplay: "",
            latestPressureDate: Date(),
            notes: "",
            installedDate: Date(),
            removedDate: Date(),
            isCurrentlyFitted: true,
            pressureUnit: .psi,
            requireValidDateCode: false,
            in: context
        )

        XCTAssertEqual(result, .savedSkippingInvalidDateCode)
        XCTAssertEqual(record.manufacturer, "Updated")
        XCTAssertEqual(record.dateCode, "1221")
        XCTAssertEqual(record.manufactureWeek, 12)
        XCTAssertEqual(record.recommendedPressurePSI, 58)
    }

    func testEmptyDateCodeClearsManufactureFields() {
        let record = makeRecord()
        record.dateCode = "1221"
        record.manufactureWeek = 12
        record.manufactureYear = 2021
        record.manufactureDate = Date()

        let result = TyreStore.applyEditorDetails(
            to: record,
            manufacturer: "",
            modelName: "",
            tyreSize: "",
            loadIndex: "",
            speedRating: "",
            dateCode: "  ",
            recommendedPressureDisplay: "",
            latestPressureDisplay: "",
            latestPressureDate: Date(),
            notes: "",
            installedDate: Date(),
            removedDate: Date(),
            isCurrentlyFitted: true,
            pressureUnit: .psi,
            requireValidDateCode: false,
            in: context
        )

        XCTAssertEqual(result, .saved)
        XCTAssertEqual(record.dateCode, "")
        XCTAssertNil(record.manufactureWeek)
        XCTAssertNil(record.manufactureYear)
        XCTAssertNil(record.manufactureDate)
    }

    private func makeRecord() -> TyreRecord {
        let record = TyreRecord(vehicleID: UUID(), position: .caravanLeft)
        context.insert(record)
        return record
    }
}

@MainActor
final class TyreInspectionDraftStoreTests: XCTestCase {
    private var tyreID: UUID!

    override func setUp() {
        tyreID = UUID()
        TyreInspectionDraftStore.clear(for: tyreID)
    }

    override func tearDown() {
        if let tyreID {
            TyreInspectionDraftStore.clear(for: tyreID)
        }
        tyreID = nil
    }

    func testEmptyDraftIsNotStored() {
        TyreInspectionDraftStore.save(emptyDraft(), images: [], for: tyreID)
        XCTAssertNil(TyreInspectionDraftStore.load(for: tyreID))
    }

    func testDraftRoundTripsTypedFields() {
        var draft = emptyDraft()
        draft.pressure = "65"
        draft.treadDepth = "5.8"
        draft.hasCuts = true
        draft.notes = "Sidewall scuff"
        draft.overallConditionRaw = TyreCondition.monitor.rawValue

        TyreInspectionDraftStore.save(draft, images: [], for: tyreID)

        let loaded = TyreInspectionDraftStore.load(for: tyreID)
        XCTAssertEqual(loaded?.pressure, "65")
        XCTAssertEqual(loaded?.treadDepth, "5.8")
        XCTAssertEqual(loaded?.hasCuts, true)
        XCTAssertEqual(loaded?.notes, "Sidewall scuff")
        XCTAssertEqual(loaded?.overallCondition, .monitor)
    }

    func testDraftRoundTripsPhotos() {
        var draft = emptyDraft()
        draft.notes = "Photo check"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }

        TyreInspectionDraftStore.save(draft, images: [(image, .sidewall)], for: tyreID)

        let loaded = TyreInspectionDraftStore.load(for: tyreID)
        XCTAssertEqual(loaded?.photos.count, 1)
        let photos = TyreInspectionDraftStore.loadPhotos(for: tyreID, from: loaded ?? draft)
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.1, .sidewall)
    }

    func testClearRemovesDraft() {
        var draft = emptyDraft()
        draft.pressure = "60"
        TyreInspectionDraftStore.save(draft, images: [], for: tyreID)
        XCTAssertNotNil(TyreInspectionDraftStore.load(for: tyreID))

        TyreInspectionDraftStore.clear(for: tyreID)
        XCTAssertNil(TyreInspectionDraftStore.load(for: tyreID))
    }

    private func emptyDraft() -> TyreInspectionDraft {
        TyreInspectionDraft(
            inspectionDate: Date(),
            pressure: "",
            treadDepth: "",
            hasCuts: false,
            hasBulges: false,
            hasCracking: false,
            hasUnevenWear: false,
            hasEmbeddedObjects: false,
            valveAppearsSound: true,
            wheelNutsChecked: true,
            overallConditionRaw: TyreCondition.good.rawValue,
            notes: "",
            photos: []
        )
    }
}
