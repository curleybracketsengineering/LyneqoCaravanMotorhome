import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import loadMate3

@MainActor
final class WarrantyEvidencePackBuilderTests: XCTestCase {
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

    func testPhotographItemsLoadServiceEventPhotosFromLinkedDocuments() throws {
        let input = try makePackInput(withPhotoNamed: "Habitation photo")
        let photos = WarrantyEvidencePackBuilder.photographItems(from: input)

        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.displayName, "Habitation photo")
        XCTAssertEqual(photos.first?.sourceTitle, input.events.first?.displayTitle)
        XCTAssertGreaterThan(photos.first?.image.size.width ?? 0, 0)
    }

    func testBuildPDFEmbedsPhotographsSection() throws {
        let input = try makePackInput(withPhotoNamed: "Damp photo")
        let data = WarrantyEvidencePackBuilder.buildPDF(input: input)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = pdf.string ?? ""

        XCTAssertTrue(text.contains("Photographs"), text)
        XCTAssertTrue(text.contains("Damp photo"), text)
        XCTAssertGreaterThan(data.count, 10_000)
    }

    private func makePackInput(withPhotoNamed name: String) throws -> WarrantyEvidencePackBuilder.Input {
        let vehicleID = UUID()
        let plan = WarrantyPlan(vehicleID: vehicleID)
        plan.manufacturer = "Bailey"
        context.insert(plan)

        let event = WarrantyEvent(vehicleID: vehicleID)
        event.yearNumber = 1
        event.serviceType = .normalService
        event.plan = plan
        context.insert(event)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        let draft = try MaintenanceAttachmentStore.draft(
            image: image,
            fileType: .photo,
            displayName: name
        )
        WarrantyStore.attachDrafts([draft], to: event, in: context)

        let documents = try context.fetch(FetchDescriptor<DocumentRecord>())
        return .init(
            plan: plan,
            events: [event],
            documents: documents,
            maintenanceRecords: [],
            faults: []
        )
    }
}
