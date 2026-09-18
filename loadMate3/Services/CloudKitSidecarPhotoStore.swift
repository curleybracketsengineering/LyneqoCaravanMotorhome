import CloudKit
import Foundation

enum CloudKitSidecarPhotoKind: String, CaseIterable {
    case attachmentFile = "attachment"
    case attachmentThumbnail = "attachmentThumb"
    case plate = "plate"
    case accident = "accident"
    case tyre = "tyre"

    var recordPrefix: String {
        switch self {
        case .attachmentFile: return "lyneqo-photo-a"
        case .attachmentThumbnail: return "lyneqo-photo-at"
        case .plate: return "lyneqo-photo-p"
        case .accident: return "lyneqo-photo-c"
        case .tyre: return "lyneqo-photo-y"
        }
    }

    func recordName(ownerID: UUID) -> String {
        "\(recordPrefix)-\(ownerID.uuidString)"
    }

    func recordID(
        ownerID: UUID,
        zoneID: CKRecordZone.ID = CKRecordZone.default().zoneID
    ) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(ownerID: ownerID), zoneID: zoneID)
    }
}

enum CloudKitSidecarPhotoRuntime {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }
}

enum CloudKitSidecarPhotoStoreError: LocalizedError {
    case missingLocalFile(URL)
    case emptyAsset(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalFile(let url):
            return "Local sidecar file is missing: \(url.lastPathComponent)"
        case .emptyAsset(let recordName):
            return "CloudKit saved \(recordName) but the asset had no bytes"
        }
    }
}

enum CloudKitSidecarPhotoExtraFields: Equatable {
    /// Dedicated sidecar type: kind, owner, file name, byte count.
    case preferred
    /// Canary type: marker + byte count.
    case canary
    /// Existing SwiftData CloudKit type: asset field only, so Production schema stays valid.
    case assetOnly
}

/// Schema variants. TestFlight/Production cannot create new record types, so uploads
/// fall through to an existing `CD_*` type in a zone SwiftData does not import.
struct CloudKitSidecarPhotoSchema: Equatable {
    let recordType: String
    let assetField: String
    let extraFields: CloudKitSidecarPhotoExtraFields
    let zoneID: CKRecordZone.ID

    static let sidecarZoneName = "LyneqoPhotoSidecar"
    static let sidecarZoneID = CKRecordZone.ID(zoneName: sidecarZoneName)
    static let defaultZoneID = CKRecordZone.default().zoneID

    var usesSidecarZone: Bool {
        zoneID.zoneName == Self.sidecarZoneName
    }

    static let preferred = CloudKitSidecarPhotoSchema(
        recordType: "LyneqoSidecarPhoto",
        assetField: "file",
        extraFields: .preferred,
        zoneID: defaultZoneID
    )

    static let compatible = CloudKitSidecarPhotoSchema(
        recordType: "LyneqoSidecarPhotoCanary",
        assetField: "jpeg",
        extraFields: .canary,
        zoneID: defaultZoneID
    )

    /// Existing Production type + asset field. Stored in a private zone so SwiftData
    /// does not import these records or put JPEG bytes back on model export.
    static let productionFallback = CloudKitSidecarPhotoSchema(
        recordType: "CD_MaintenanceAttachment",
        assetField: "CD_fileData",
        extraFields: .assetOnly,
        zoneID: sidecarZoneID
    )

    static let productionTyreFallback = CloudKitSidecarPhotoSchema(
        recordType: "CD_TyrePhoto",
        assetField: "CD_imageData",
        extraFields: .assetOnly,
        zoneID: sidecarZoneID
    )

    static let productionPlateFallback = CloudKitSidecarPhotoSchema(
        recordType: "CD_VehicleProfile",
        assetField: "CD_manufacturerPlatePhotoData",
        extraFields: .assetOnly,
        zoneID: sidecarZoneID
    )

    static let all = [
        preferred,
        compatible,
        productionFallback,
        productionTyreFallback,
        productionPlateFallback,
    ]

    static func matching(recordType: String) -> CloudKitSidecarPhotoSchema {
        all.first { $0.recordType == recordType } ?? productionFallback
    }
}

/// Private-DB `CKAsset` records for photos. Separate from SwiftData so export is not poisoned.
enum CloudKitSidecarPhotoStore {
    static let recordType = CloudKitSidecarPhotoSchema.preferred.recordType
    static let assetField = CloudKitSidecarPhotoSchema.preferred.assetField
    static let kindField = "kind"
    static let ownerField = "ownerID"
    static let fileNameField = "fileName"
    static let byteCountField = "byteCount"

    @discardableResult
    static func upload(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        fileURL: URL,
        containerID: String = LoadMateModelContainer.cloudKitContainerID
    ) async throws -> CloudKitSidecarPhotoSchema {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CloudKitSidecarPhotoStoreError.missingLocalFile(fileURL)
        }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let uploadURL = try copyForUpload(fileURL)
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        let database = CKContainer(identifier: containerID).privateCloudDatabase
        let recordName = kind.recordName(ownerID: ownerID)

        if let existing = try await existingRecord(kind: kind, ownerID: ownerID, database: database) {
            let schema = CloudKitSidecarPhotoSchema.matching(recordType: existing.recordType)
            applyAsset(
                to: existing,
                schema: schema,
                kind: kind,
                ownerID: ownerID,
                fileName: fileURL.lastPathComponent,
                byteCount: byteCount,
                uploadURL: uploadURL
            )
            _ = try await database.save(existing)
            try await verifyAsset(recordID: existing.recordID, database: database)
            return schema
        }

        var lastError: Error = CloudKitSidecarPhotoStoreError.emptyAsset(recordName)
        for schema in CloudKitSidecarPhotoSchema.all {
            do {
                if schema.usesSidecarZone {
                    try await ensureSidecarZone(database: database)
                }
                let recordID = kind.recordID(ownerID: ownerID, zoneID: schema.zoneID)
                let record = CKRecord(recordType: schema.recordType, recordID: recordID)
                applyAsset(
                    to: record,
                    schema: schema,
                    kind: kind,
                    ownerID: ownerID,
                    fileName: fileURL.lastPathComponent,
                    byteCount: byteCount,
                    uploadURL: uploadURL
                )
                _ = try await database.save(record)
                try await verifyAsset(recordID: recordID, database: database)
                return schema
            } catch {
                lastError = error
                debugLog(
                    "upload skip \(schema.recordType) zone=\(schema.zoneID.zoneName) — \(CloudSyncErrorFormatting.flatten(error).joined(separator: " | "))"
                )
                if !isSchemaError(error) {
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Temporary copy for `CKAsset`. The live sidecar file stays in Application Support.
    static func copyForUpload(_ fileURL: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyneqo-sidecar-\(UUID().uuidString)-\(fileURL.lastPathComponent)")
        try FileManager.default.copyItem(at: fileURL, to: temp)
        return temp
    }

    @discardableResult
    static func download(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        destinationURL: URL,
        containerID: String = LoadMateModelContainer.cloudKitContainerID
    ) async throws -> Bool {
        let database = CKContainer(identifier: containerID).privateCloudDatabase
        guard let record = try await existingRecord(kind: kind, ownerID: ownerID, database: database) else {
            return false
        }
        guard let data = assetData(from: record), !data.isEmpty else {
            return false
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: .atomic)
        return true
    }

    static func delete(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        containerID: String = LoadMateModelContainer.cloudKitContainerID
    ) async throws {
        let database = CKContainer(identifier: containerID).privateCloudDatabase
        for zoneID in searchZoneIDs {
            do {
                try await database.deleteRecord(withID: kind.recordID(ownerID: ownerID, zoneID: zoneID))
            } catch {
                if isMissingRecord(error) { continue }
                throw error
            }
        }
    }

    static func isUnknownItem(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain, nsError.code == CKError.Code.unknownItem.rawValue {
            return true
        }
        if let ckError = error as? CKError {
            if ckError.code == .unknownItem { return true }
            if let partial = ckError.partialErrorsByItemID {
                return partial.values.allSatisfy { isUnknownItem($0) }
            }
        }
        return false
    }

    static func isMissingRecord(_ error: Error) -> Bool {
        if isUnknownItem(error) { return true }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .zoneNotFound, .userDeletedZone:
                return true
            default:
                break
            }
            if let partial = ckError.partialErrorsByItemID {
                return partial.values.allSatisfy { isMissingRecord($0) }
            }
        }
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain {
            let code = nsError.code
            if code == CKError.Code.zoneNotFound.rawValue || code == CKError.Code.userDeletedZone.rawValue {
                return true
            }
        }
        return false
    }

    static func isSchemaError(_ error: Error) -> Bool {
        if isUnknownItem(error) { return true }
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain, nsError.code == CKError.Code.invalidArguments.rawValue {
            return true
        }
        if let ckError = error as? CKError, ckError.code == .invalidArguments {
            return true
        }
        let text = CloudSyncErrorFormatting.flatten(error).joined(separator: " ").lowercased()
        return text.contains("record type")
            || text.contains("unknown field")
            || text.contains("invalid arguments")
            || text.contains("not allowed")
            || text.contains("reserved")
    }

    static func assetData(from record: CKRecord) -> Data? {
        for field in assetFieldNames {
            if let asset = record[field] as? CKAsset,
               let source = asset.fileURL,
               FileManager.default.fileExists(atPath: source.path),
               let data = try? Data(contentsOf: source),
               !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private static let assetFieldNames = [
        CloudKitSidecarPhotoSchema.preferred.assetField,
        CloudKitSidecarPhotoSchema.compatible.assetField,
        CloudKitSidecarPhotoSchema.productionFallback.assetField,
        CloudKitSidecarPhotoSchema.productionTyreFallback.assetField,
        "CD_thumbnailData",
        CloudKitSidecarPhotoSchema.productionPlateFallback.assetField,
    ]

    private static var searchZoneIDs: [CKRecordZone.ID] {
        var seen = Set<String>()
        var result: [CKRecordZone.ID] = []
        for schema in CloudKitSidecarPhotoSchema.all {
            if seen.insert(schema.zoneID.zoneName).inserted {
                result.append(schema.zoneID)
            }
        }
        return result
    }

    private static var didEnsureSidecarZone = false

    private static func ensureSidecarZone(database: CKDatabase) async throws {
        if didEnsureSidecarZone { return }
        do {
            _ = try await database.save(CKRecordZone(zoneID: CloudKitSidecarPhotoSchema.sidecarZoneID))
            didEnsureSidecarZone = true
        } catch let error as CKError where error.code == .serverRecordChanged {
            didEnsureSidecarZone = true
        }
    }

    private static func existingRecord(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        database: CKDatabase
    ) async throws -> CKRecord? {
        for zoneID in searchZoneIDs {
            do {
                return try await database.record(for: kind.recordID(ownerID: ownerID, zoneID: zoneID))
            } catch {
                if isMissingRecord(error) { continue }
                throw error
            }
        }
        return nil
    }

    private static func applyAsset(
        to record: CKRecord,
        schema: CloudKitSidecarPhotoSchema,
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        fileName: String,
        byteCount: Int,
        uploadURL: URL
    ) {
        record[schema.assetField] = CKAsset(fileURL: uploadURL)
        switch schema.extraFields {
        case .preferred:
            record[byteCountField] = NSNumber(value: byteCount)
            record[kindField] = kind.rawValue as CKRecordValue
            record[ownerField] = ownerID.uuidString as CKRecordValue
            record[fileNameField] = fileName as CKRecordValue
        case .canary:
            record[byteCountField] = NSNumber(value: byteCount)
            record[CloudKitSidecarAssetCanary.markerField] = kind.rawValue as CKRecordValue
        case .assetOnly:
            break
        }
    }

    private static func verifyAsset(recordID: CKRecord.ID, database: CKDatabase) async throws {
        let fetched = try await database.record(for: recordID)
        guard let data = assetData(from: fetched), !data.isEmpty else {
            throw CloudKitSidecarPhotoStoreError.emptyAsset(recordID.recordName)
        }
    }

    private static func debugLog(_ message: String) {
        Task { @MainActor in
            SyncDebugLogger.shared.record(category: "sidecar-photo", message: message)
        }
    }
}

actor CloudKitSidecarPhotoWorker {
    static let shared = CloudKitSidecarPhotoWorker()

    @discardableResult
    func upload(kind: CloudKitSidecarPhotoKind, ownerID: UUID, fileURL: URL) async -> Bool {
        do {
            let schema = try await CloudKitSidecarPhotoStore.upload(
                kind: kind,
                ownerID: ownerID,
                fileURL: fileURL
            )
            log(
                "upload OK \(kind.recordName(ownerID: ownerID)) type=\(schema.recordType) zone=\(schema.zoneID.zoneName)"
            )
            return true
        } catch {
            log("upload FAILED \(kind.recordName(ownerID: ownerID)) — \(CloudSyncErrorFormatting.flatten(error).joined(separator: " | "))")
            return false
        }
    }

    func download(kind: CloudKitSidecarPhotoKind, ownerID: UUID, destinationURL: URL) async -> Bool {
        do {
            let ok = try await CloudKitSidecarPhotoStore.download(
                kind: kind,
                ownerID: ownerID,
                destinationURL: destinationURL
            )
            if ok {
                log("download OK \(kind.recordName(ownerID: ownerID))")
            } else {
                log("download miss \(kind.recordName(ownerID: ownerID)) — not in CloudKit yet")
            }
            return ok
        } catch {
            log("download FAILED \(kind.recordName(ownerID: ownerID)) — \(CloudSyncErrorFormatting.flatten(error).joined(separator: " | "))")
            return false
        }
    }

    func delete(kind: CloudKitSidecarPhotoKind, ownerID: UUID) async {
        do {
            try await CloudKitSidecarPhotoStore.delete(kind: kind, ownerID: ownerID)
            log("delete OK \(kind.recordName(ownerID: ownerID))")
        } catch {
            log("delete FAILED \(kind.recordName(ownerID: ownerID)) — \(CloudSyncErrorFormatting.flatten(error).joined(separator: " | "))")
        }
    }

    private func log(_ message: String) {
        Task { @MainActor in
            SyncDebugLogger.shared.record(category: "sidecar-photo", message: message)
        }
    }
}
