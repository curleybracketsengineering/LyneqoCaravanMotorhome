import SwiftData
import UIKit
import XCTest
@testable import loadMate3

@MainActor
final class TyrePhotoStoreTests: XCTestCase {
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

    func testSaveAndLoadPhoto() throws {
        let profile = TestFixtures.caravanProfile()
        context.insert(profile)
        let record = TyreRecord(vehicleID: profile.id, position: .caravanLeft)
        context.insert(record)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }

        let photo = try TyrePhotoStore.save(
            image: image,
            vehicleID: profile.id,
            record: record,
            inspection: nil,
            kind: .sidewall,
            in: context
        )

        XCTAssertFalse(photo.localFileName.isEmpty)
        XCTAssertEqual(photo.kind, .sidewall)
        XCTAssertEqual(photo.tyreRecordID, record.id)
        XCTAssertNil(photo.inspection)
        XCTAssertNil(photo.imageData)

        let loaded = TyrePhotoStore.loadImage(for: photo, vehicleID: profile.id)
        XCTAssertNotNil(loaded)
    }

    func testLoadDoesNotUseCloudKitAssetBytesAfterSave() throws {
        let profile = TestFixtures.caravanProfile()
        context.insert(profile)
        let record = TyreRecord(vehicleID: profile.id, position: .caravanLeft)
        context.insert(record)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let photo = try TyrePhotoStore.save(
            image: image,
            vehicleID: profile.id,
            record: record,
            inspection: nil,
            kind: .tread,
            in: context
        )
        let url = try TyrePhotoStore.fileURL(vehicleID: profile.id, fileName: photo.localFileName)
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(photo.imageData)
        XCTAssertNil(TyrePhotoStore.loadImage(for: photo, vehicleID: profile.id))
    }

    func testResizeReducesLargeImages() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { _ in }
        let resized = TyrePhotoStore.resize(image: image, maxDimension: 2048)
        XCTAssertLessThanOrEqual(max(resized.size.width, resized.size.height), 2048)
    }

    func testInspectionPhotosAreFilteredSeparately() throws {
        let vehicleID = UUID()
        let record = TyreRecord(vehicleID: vehicleID, position: .caravanLeft)
        context.insert(record)

        let inspection = TyreInspection(tyreRecord: record)
        context.insert(inspection)

        let general = TyrePhoto(
            tyreRecord: record,
            inspection: nil,
            kind: .general,
            localFileName: "general.jpg"
        )
        let inspectionPhoto = TyrePhoto(
            tyreRecord: record,
            inspection: inspection,
            kind: .tread,
            localFileName: "tread.jpg"
        )
        context.insert(general)
        context.insert(inspectionPhoto)

        XCTAssertEqual(record.generalPhotosList().count, 1)
        XCTAssertEqual(TyrePhotoStore.photos(for: record, inspection: inspection).count, 1)
    }

    func testDiagramPhotoPrefersFullTyreOverSidewall() {
        let record = TyreRecord(vehicleID: UUID(), position: .caravanLeft)
        let sidewall = TyrePhoto(
            tyreRecord: record,
            inspection: nil,
            kind: .sidewall,
            capturedAt: Date().addingTimeInterval(-60),
            localFileName: "sidewall.jpg"
        )
        let fullTyre = TyrePhoto(
            tyreRecord: record,
            inspection: nil,
            kind: .fullTyre,
            capturedAt: Date(),
            localFileName: "full.jpg"
        )
        record.photos = [sidewall, fullTyre]

        XCTAssertEqual(TyrePhotoStore.diagramPhoto(for: record)?.kind, .fullTyre)
    }
}
