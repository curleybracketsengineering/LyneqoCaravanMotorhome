import CloudKit
import XCTest
@testable import loadMate3

final class CloudKitSidecarPhotoStoreTests: XCTestCase {
    func testRecordNamesAreStableAndUniquePerKind() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.attachmentFile.recordName(ownerID: id),
            "lyneqo-photo-a-\(id.uuidString)"
        )
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.attachmentThumbnail.recordName(ownerID: id),
            "lyneqo-photo-at-\(id.uuidString)"
        )
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.plate.recordName(ownerID: id),
            "lyneqo-photo-p-\(id.uuidString)"
        )
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.accident.recordName(ownerID: id),
            "lyneqo-photo-c-\(id.uuidString)"
        )
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.tyre.recordName(ownerID: id),
            "lyneqo-photo-y-\(id.uuidString)"
        )

        let names = CloudKitSidecarPhotoKind.allCases.map { $0.recordName(ownerID: id) }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testRecordTypeAndAssetFieldStayOffSwiftData() {
        XCTAssertEqual(CloudKitSidecarPhotoStore.recordType, "LyneqoSidecarPhoto")
        XCTAssertEqual(CloudKitSidecarPhotoStore.assetField, "file")
        XCTAssertEqual(CloudKitSidecarPhotoSchema.compatible.recordType, "LyneqoSidecarPhotoCanary")
        XCTAssertEqual(CloudKitSidecarPhotoSchema.compatible.assetField, "jpeg")
        XCTAssertEqual(CloudKitSidecarAssetCanary.recordType, CloudKitSidecarPhotoSchema.compatible.recordType)
        XCTAssertEqual(CloudKitSidecarAssetCanary.assetField, CloudKitSidecarPhotoSchema.compatible.assetField)
        XCTAssertNotEqual(CloudKitSidecarPhotoStore.recordType, CloudKitSidecarAssetCanary.recordType)
        XCTAssertEqual(
            CloudKitSidecarPhotoSchema.matching(recordType: "LyneqoSidecarPhotoCanary"),
            CloudKitSidecarPhotoSchema.compatible
        )
        XCTAssertEqual(CloudKitSidecarPhotoSchema.productionFallback.recordType, "CD_MaintenanceAttachment")
        XCTAssertEqual(CloudKitSidecarPhotoSchema.productionFallback.assetField, "CD_fileData")
        XCTAssertEqual(CloudKitSidecarPhotoSchema.productionFallback.extraFields, .assetOnly)
        XCTAssertEqual(
            CloudKitSidecarPhotoSchema.productionFallback.zoneID.zoneName,
            CloudKitSidecarPhotoSchema.sidecarZoneName
        )
        XCTAssertTrue(CloudKitSidecarPhotoSchema.all.contains(CloudKitSidecarPhotoSchema.productionFallback))
        XCTAssertEqual(
            CloudKitSidecarPhotoSchema.matching(recordType: "CD_MaintenanceAttachment"),
            CloudKitSidecarPhotoSchema.productionFallback
        )
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.plate.recordID(ownerID: id).zoneID.zoneName,
            CKRecordZone.default().zoneID.zoneName
        )
        XCTAssertEqual(
            CloudKitSidecarPhotoKind.plate.recordID(
                ownerID: id,
                zoneID: CloudKitSidecarPhotoSchema.sidecarZoneID
            ).zoneID.zoneName,
            CloudKitSidecarPhotoSchema.sidecarZoneName
        )
    }

    func testUnknownItemDetection() {
        let unknown = CKError(.unknownItem)
        XCTAssertTrue(CloudKitSidecarPhotoStore.isUnknownItem(unknown))
        XCTAssertTrue(CloudKitSidecarPhotoStore.isSchemaError(unknown))
        XCTAssertTrue(CloudKitSidecarPhotoStore.isSchemaError(CKError(.invalidArguments)))
        XCTAssertFalse(CloudKitSidecarPhotoStore.isUnknownItem(CKError(.networkUnavailable)))
        XCTAssertFalse(CloudKitSidecarPhotoStore.isSchemaError(CKError(.networkUnavailable)))
    }

    func testCopyForUploadLeavesOriginalFileInPlace() throws {
        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyneqo-original-\(UUID().uuidString).pdf")
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        try bytes.write(to: original, options: .atomic)
        defer { try? FileManager.default.removeItem(at: original) }

        let copy = try CloudKitSidecarPhotoStore.copyForUpload(original)
        defer { try? FileManager.default.removeItem(at: copy) }

        XCTAssertNotEqual(original.path, copy.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }
}
