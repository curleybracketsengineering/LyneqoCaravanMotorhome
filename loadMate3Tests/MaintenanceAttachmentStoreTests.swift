import SwiftData
import UIKit
import XCTest
@testable import loadMate3

@MainActor
final class MaintenanceAttachmentStoreTests: XCTestCase {
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

    func testSaveAndLoadPhotoAttachment() throws {
        let vehicleID = UUID()
        let record = MaintenanceRecord(vehicleID: vehicleID)
        context.insert(record)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 320)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 320))
        }

        let draft = try MaintenanceAttachmentStore.draft(
            image: image,
            fileType: .photo,
            displayName: "Service photo"
        )

        let attachment = try MaintenanceAttachmentStore.save(
            draft: draft,
            to: .maintenance(record),
            in: context
        )

        XCTAssertEqual(attachment.fileType, .photo)
        XCTAssertEqual(attachment.displayName, "Service photo")
        XCTAssertNil(attachment.fileData)
        XCTAssertNil(attachment.thumbnailData)
        XCTAssertNotNil(MaintenanceAttachmentStore.loadImage(for: attachment))
        XCTAssertNotNil(MaintenanceAttachmentStore.loadThumbnail(for: attachment))
    }

    func testLoadDoesNotUseCloudKitAssetBytesAfterSave() throws {
        let vehicleID = UUID()
        let record = MaintenanceRecord(vehicleID: vehicleID)
        context.insert(record)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        let draft = try MaintenanceAttachmentStore.draft(
            image: image,
            fileType: .photo,
            displayName: "Invoice photo"
        )
        let attachment = try MaintenanceAttachmentStore.save(
            draft: draft,
            to: .maintenance(record),
            in: context
        )
        let url = try MaintenanceAttachmentStore.fileURL(vehicleID: vehicleID, fileName: attachment.localFileName)
        try FileManager.default.removeItem(at: url)
        if let thumbnailFileName = attachment.thumbnailFileName {
            let thumbURL = try MaintenanceAttachmentStore.fileURL(vehicleID: vehicleID, fileName: thumbnailFileName)
            try? FileManager.default.removeItem(at: thumbURL)
        }

        XCTAssertNil(attachment.fileData)
        XCTAssertNil(attachment.thumbnailData)
        XCTAssertNil(MaintenanceAttachmentStore.loadImage(for: attachment))
    }

    func testSaveScannedDocumentKeepsPageCount() throws {
        let vehicleID = UUID()
        let document = DocumentRecord(vehicleID: vehicleID)
        context.insert(document)

        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300)).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }

        let draft = MaintenanceAttachmentStore.draft(
            pdfData: pdfData,
            displayName: "Scanned certificate",
            pageCount: 1,
            fileType: .scannedDocument
        )

        let attachment = try MaintenanceAttachmentStore.save(
            draft: draft,
            to: .document(document),
            in: context
        )

        XCTAssertEqual(attachment.fileType, .scannedDocument)
        XCTAssertEqual(attachment.pageCount, 1)
        XCTAssertNil(attachment.fileData)
        XCTAssertNil(attachment.thumbnailData)
        XCTAssertNotNil(MaintenanceAttachmentStore.loadThumbnail(for: attachment))
        let url = try MaintenanceAttachmentStore.fileURL(vehicleID: vehicleID, fileName: attachment.localFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveDraftsToDocumentKeepsFilesOnDisk() throws {
        let vehicleID = UUID()
        let document = DocumentRecord(vehicleID: vehicleID)
        document.title = "CRiS Registration"
        context.insert(document)

        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let draft = MaintenanceAttachmentStore.draft(
            pdfData: pdfData,
            displayName: "CRIS number",
            pageCount: 1,
            fileType: .pdf
        )

        MaintenanceAttachmentStore.save(drafts: [draft], to: .document(document), in: context)

        XCTAssertEqual(document.attachmentsList.count, 1)
        let attachment = try XCTUnwrap(document.attachmentsList.first)
        XCTAssertEqual(attachment.documentRecord?.id, document.id)
        XCTAssertNil(attachment.fileData)
        let url = try MaintenanceAttachmentStore.fileURL(vehicleID: vehicleID, fileName: attachment.localFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
