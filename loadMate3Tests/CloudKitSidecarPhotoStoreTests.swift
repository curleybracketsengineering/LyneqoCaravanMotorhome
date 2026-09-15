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
        XCTAssertNotEqual(CloudKitSidecarPhotoStore.recordType, CloudKitSidecarAssetCanary.recordType)
    }

    func testUnknownItemDetection() {
        let unknown = CKError(.unknownItem)
        XCTAssertTrue(CloudKitSidecarPhotoStore.isUnknownItem(unknown))
        XCTAssertFalse(CloudKitSidecarPhotoStore.isUnknownItem(CKError(.networkUnavailable)))
    }
}
