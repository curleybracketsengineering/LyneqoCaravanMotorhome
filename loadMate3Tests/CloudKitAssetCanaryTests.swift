import CloudKit
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import loadMate3

@MainActor
final class CloudKitAssetCanaryTests: XCTestCase {
    func testTinyJPEGIsSmall() {
        let data = CloudKitAssetCanary.makeTinyJPEG()
        XCTAssertFalse(data.isEmpty)
        XCTAssertLessThan(data.count, 2_048)
    }

    func testDiagnosticNamesUseCloudKitPrefix() {
        XCTAssertTrue(CloudKitAssetCanary.documentTitle.hasPrefix(CloudKitDiagnosticMarkers.namePrefix))
        XCTAssertTrue(CloudKitAssetCanary.attachmentName.hasPrefix(CloudKitDiagnosticMarkers.namePrefix))
        XCTAssertEqual(CloudKitDiagnosticMarkers.isClearlyDiagnosticName(CloudKitAssetCanary.documentTitle), CloudKitDiagnosticMarkers.namePrefix)
        XCTAssertTrue(CloudKitAssetCanary.documentOnlyTitle.hasPrefix(CloudKitDiagnosticMarkers.namePrefix))
        XCTAssertEqual(CloudKitDiagnosticMarkers.isClearlyDiagnosticName(CloudKitAssetCanary.attachmentMetaName), CloudKitDiagnosticMarkers.namePrefix)
        XCTAssertEqual(CloudKitDiagnosticMarkers.isClearlyDiagnosticName(CloudKitSidecarAssetCanary.markerValue), CloudKitDiagnosticMarkers.namePrefix)
        XCTAssertEqual(CloudKitSidecarAssetCanary.recordType, "LyneqoSidecarPhotoCanary")
        XCTAssertEqual(CloudKitSidecarAssetCanary.assetField, "jpeg")
    }

    func testSidecarCanaryWritesJPEGFileForCKAsset() throws {
        let jpeg = CloudKitAssetCanary.makeTinyJPEG()
        let url = try CloudKitSidecarAssetCanary.writeTemporaryJPEG(jpeg)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
        let asset = CKAsset(fileURL: url)
        XCTAssertEqual(asset.fileURL?.path, url.path)
    }

    func testAuditFindsCanaryDocumentAndAttachment() throws {
        let context = try makeContext()
        let profile = VehicleProfile(name: "Van", kind: .caravan, sortOrder: 0)
        context.insert(profile)

        let document = DocumentRecord(vehicleID: profile.id)
        document.title = CloudKitAssetCanary.documentTitle
        context.insert(document)

        let jpeg = CloudKitAssetCanary.makeTinyJPEG()
        let attachment = MaintenanceAttachment(
            vehicleID: profile.id,
            localFileName: "canary.jpg",
            fileType: .photo,
            displayName: CloudKitAssetCanary.attachmentName,
            utiIdentifier: UTType.jpeg.identifier,
            byteCount: jpeg.count
        )
        attachment.fileData = jpeg
        attachment.documentRecord = document
        context.insert(attachment)
        try context.save()

        let report = CloudKitDiagnosticAuditor.audit(in: context)
        XCTAssertEqual(report.summaries.first { $0.model == "DocumentRecord" }?.clearlyDiagnostic, 1)
        XCTAssertEqual(report.summaries.first { $0.model == "MaintenanceAttachment" }?.clearlyDiagnostic, 1)
        XCTAssertTrue(report.removalPlan.removable.contains { $0.model == "DocumentRecord" })
        XCTAssertTrue(report.removalPlan.removable.contains { $0.model == "MaintenanceAttachment" })
    }

    func testRemovalDeletesCanaryDocument() throws {
        let context = try makeContext()
        let document = DocumentRecord(vehicleID: UUID())
        document.title = CloudKitAssetCanary.documentTitle
        context.insert(document)
        try context.save()

        _ = try CloudKitDiagnosticAuditor.removeClearlyDiagnosticRecords(in: context)
        let remaining = try context.fetch(FetchDescriptor<DocumentRecord>())
        XCTAssertTrue(remaining.isEmpty)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            VehicleProfile.self,
            DocumentRecord.self,
            MaintenanceAttachment.self,
            WarrantyEvent.self,
            WarrantyPlan.self,
            MaintenanceRecord.self,
            FaultRecord.self,
            AppState.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
