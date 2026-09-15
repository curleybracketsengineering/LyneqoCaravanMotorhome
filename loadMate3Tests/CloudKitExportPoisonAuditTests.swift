import CloudKit
import SwiftData
import XCTest
@testable import loadMate3

@MainActor
final class CloudKitExportPoisonAuditTests: XCTestCase {
    func testHealthyMigratedChecklistHasNoLikelyFindings() throws {
        let context = try makeContext()
        let state = AppState()
        state.didMigrateChecklistsToVehicles = true
        context.insert(state)

        let caravan = VehicleProfile(name: "Van", kind: .caravan, sortOrder: 0)
        context.insert(caravan)
        _ = LoadMateChecklistSeedTemplate.insertAll(onto: caravan, in: context)

        let report = CloudKitExportPoisonAudit.audit(in: context)
        XCTAssertTrue(report.findings.filter { $0.severity == .likely }.isEmpty)
        XCTAssertTrue(report.formatted.contains("none in the local graph"))
        XCTAssertEqual(report.local.sectionCount, 5)
        XCTAssertTrue(report.local.didMigrateChecklistsToVehicles)
        XCTAssertTrue(report.local.modelCounts.contains { $0.model == "ChecklistSection" && $0.count == 5 })
        XCTAssertTrue(report.formatted.contains("LOCAL MODEL COUNTS"))
        XCTAssertTrue(report.formatted.contains("LOCAL ASSETS"))
    }

    func testFlagsUnscopedSectionsAfterMigration() throws {
        let context = try makeContext()
        let state = AppState()
        state.didMigrateChecklistsToVehicles = true
        context.insert(state)
        context.insert(ChecklistSection(title: "Shared leftover", sortOrder: 0))

        let report = CloudKitExportPoisonAudit.audit(in: context)
        XCTAssertTrue(report.findings.contains { $0.code == "unscoped-after-migrate" })
        XCTAssertTrue(report.formatted.contains("unscoped-after-migrate"))
    }

    func testFlagsDuplicateSectionTitlesOnTheSameVehicle() throws {
        let context = try makeContext()
        context.insert(AppState())
        let caravan = VehicleProfile(name: "Van", kind: .caravan, sortOrder: 0)
        context.insert(caravan)
        context.insert(ChecklistSection(title: "Pitching", sortOrder: 0, profile: caravan))
        context.insert(ChecklistSection(title: "Pitching", sortOrder: 1, profile: caravan))

        let report = CloudKitExportPoisonAudit.audit(in: context)
        XCTAssertTrue(report.findings.contains { $0.code == "duplicate-title-on-vehicle" })
    }

    func testFlagsOrphanGroupAndItem() throws {
        let context = try makeContext()
        context.insert(AppState())
        context.insert(ChecklistGroup(title: "Loose group", sortOrder: 0))
        context.insert(ChecklistItem(title: "Loose item", isChecked: false, sortOrder: 0))

        let report = CloudKitExportPoisonAudit.audit(in: context)
        XCTAssertTrue(report.findings.contains { $0.code == "orphan-group" })
        XCTAssertTrue(report.findings.contains { $0.code == "orphan-item" })
    }

    func testFlagsDuplicateSectionIDs() throws {
        let context = try makeContext()
        context.insert(AppState())
        let sharedID = UUID()
        context.insert(ChecklistSection(id: sharedID, title: "One", sortOrder: 0))
        context.insert(ChecklistSection(id: sharedID, title: "Two", sortOrder: 1))

        let report = CloudKitExportPoisonAudit.audit(in: context)
        XCTAssertTrue(report.findings.contains { $0.code == "duplicate-id" && $0.detail.contains("ChecklistSection") })
    }

    func testCompareIDsSplitsLocalOnlyAndCloudOnly() {
        let localA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let shared = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let cloudC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let diff = CloudKitExportPoisonAudit.compareIDs(local: [localA, shared], cloud: [shared, cloudC])
        XCTAssertEqual(diff.localOnly, [localA])
        XCTAssertEqual(diff.cloudOnly, [cloudC])
    }

    func testUUIDParsingAndFieldFormatting() {
        let uuid = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        XCTAssertEqual(CloudKitExportPoisonAudit.uuid(fromCloudValue: uuid.uuidString), uuid)
        XCTAssertEqual(CloudKitExportPoisonAudit.formattedField(nil as CKRecordValueProtocol?), "(nil)")
        XCTAssertEqual(CloudKitExportPoisonAudit.formattedField(""), "(empty)")
        XCTAssertEqual(CloudKitExportPoisonAudit.formattedField("Before leaving home"), "Before leaving home")
        let reference = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "vehicle-1"),
            action: .none
        )
        XCTAssertTrue(CloudKitExportPoisonAudit.formattedField(reference).contains("vehicle-1"))
    }

    func testCopiedReportIncludesExportPoisonSection() {
        let snapshot = SyncDebugSnapshot(
            accountStatus: .available,
            lastCheckedAt: nil,
            lastErrorDescription: nil,
            lastSyncEventSummary: "None yet",
            recentSyncEventLines: [],
            lastSuccessfulImportAt: nil,
            lastSuccessfulExportAt: nil,
            lastDetailedCloudKitFailure: nil,
            lastMinimalSyncTestResult: "Not run",
            lastAssetCanaryResult: "Not run",
            cloudKitIsolationTestReport: "unused",
            isRegisteredForRemoteNotifications: false,
            pushRegistrationDetail: "",
            cloudKitSchemaDetail: "Not checked yet",
            exportPoisonReport: "Export poison audit\nLIKELY PROBLEMS\nnone in the local graph",
            deviceName: "Test",
            bundleID: "test",
            appVersion: "4.0",
            buildNumber: "1",
            vehicleProfileCount: 0,
            tripCount: 0,
            loadedItemCount: 0,
            libraryItemCount: 0,
            checklistSectionCount: 0,
            checklistItemCount: 0,
            appStateCount: 1,
            activeProfileName: nil,
            syncProbeSequence: 0,
            syncProbeValue: "",
            syncProbeUpdatedAt: nil,
            syncProbeUpdatedBy: ""
        )
        let report = SyncDebugLogger.shared.makeReport(snapshot: snapshot)
        XCTAssertTrue(report.contains("Export poison audit"))
        XCTAssertTrue(report.contains("none in the local graph"))
        XCTAssertTrue(report.contains("5. Compare Local vs CloudKit"))
    }

    func testSyncDebugTestNumbersStayStable() {
        XCTAssertEqual(SyncDebugTestCatalog.refreshICloud, 1)
        XCTAssertEqual(SyncDebugTestCatalog.checkSchema, 2)
        XCTAssertEqual(SyncDebugTestCatalog.writeSyncProbe, 3)
        XCTAssertEqual(SyncDebugTestCatalog.minimalSync, 4)
        XCTAssertEqual(SyncDebugTestCatalog.compareLocalVsCloudKit, 5)
        XCTAssertEqual(SyncDebugTestCatalog.productionHealth, 6)
        XCTAssertEqual(SyncDebugTestCatalog.diagnosticAudit, 7)
        XCTAssertEqual(SyncDebugTestCatalog.isolationLibraryItem, 17)
        XCTAssertEqual(SyncDebugTestCatalog.tinyAssetCanary, 18)
        XCTAssertEqual(SyncDebugTestCatalog.tinyAssetCanaryWithThumbnail, 19)
        XCTAssertEqual(SyncDebugTestCatalog.seedSectionNumber(0), 20)
        XCTAssertEqual(SyncDebugTestCatalog.watchVehicle, 30)
        XCTAssertEqual(SyncDebugTestCatalog.documentOnlyCanary, 32)
        XCTAssertEqual(SyncDebugTestCatalog.attachmentMetaCanary, 33)
        XCTAssertEqual(SyncDebugTestCatalog.sidecarCKAssetCanary, 34)
        XCTAssertTrue(SyncDebugTestCatalog.indexText.contains("18. Run Tiny Asset Canary"))
        XCTAssertTrue(SyncDebugTestCatalog.indexText.contains("19. Run Tiny Asset Canary With Thumbnail"))
        XCTAssertTrue(SyncDebugTestCatalog.indexText.contains("32. Run Document Canary (No File)"))
        XCTAssertTrue(SyncDebugTestCatalog.indexText.contains("33. Run Attachment Canary (No Bytes)"))
        XCTAssertTrue(SyncDebugTestCatalog.indexText.contains("34. Run Sidecar CKAsset Canary"))
        XCTAssertTrue(SyncDebugTestCatalog.title(5, "Compare Local vs CloudKit").hasPrefix("5. "))
        let numbers = SyncDebugTestCatalog.indexLines.compactMap { line -> Int? in
            Int(line.split(separator: ".", maxSplits: 1).first ?? "")
        }
        XCTAssertEqual(numbers, numbers.sorted())
        XCTAssertEqual(numbers.first, 1)
        XCTAssertEqual(numbers.last, 34)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            VehicleProfile.self,
            Trip.self,
            LoadedItem.self,
            LibraryItem.self,
            ChecklistSection.self,
            ChecklistGroup.self,
            ChecklistItem.self,
            AppState.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
