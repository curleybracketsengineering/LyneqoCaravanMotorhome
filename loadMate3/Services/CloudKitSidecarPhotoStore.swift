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

    func recordID(ownerID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(ownerID: ownerID))
    }
}

enum CloudKitSidecarPhotoRuntime {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }
}

/// Private-DB `CKAsset` records for photos. Separate from SwiftData so export is not poisoned.
enum CloudKitSidecarPhotoStore {
    static let recordType = "LyneqoSidecarPhoto"
    static let assetField = "file"
    static let kindField = "kind"
    static let ownerField = "ownerID"
    static let fileNameField = "fileName"
    static let byteCountField = "byteCount"

    static func upload(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        fileURL: URL,
        containerID: String = LoadMateModelContainer.cloudKitContainerID
    ) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let database = CKContainer(identifier: containerID).privateCloudDatabase
        let recordID = kind.recordID(ownerID: ownerID)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch {
            if isUnknownItem(error) {
                record = CKRecord(recordType: recordType, recordID: recordID)
            } else {
                throw error
            }
        }
        record[kindField] = kind.rawValue as CKRecordValue
        record[ownerField] = ownerID.uuidString as CKRecordValue
        record[fileNameField] = fileURL.lastPathComponent as CKRecordValue
        record[byteCountField] = NSNumber(value: byteCount)
        // Copy first so CloudKit cannot consume the live Application Support file.
        let uploadURL = try copyForUpload(fileURL)
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        record[assetField] = CKAsset(fileURL: uploadURL)
        _ = try await database.save(record)
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
        let record: CKRecord
        do {
            record = try await database.record(for: kind.recordID(ownerID: ownerID))
        } catch {
            if isUnknownItem(error) {
                return false
            }
            throw error
        }
        guard let asset = record[assetField] as? CKAsset,
              let source = asset.fileURL,
              FileManager.default.fileExists(atPath: source.path) else {
            return false
        }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { return false }
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
        do {
            try await database.deleteRecord(withID: kind.recordID(ownerID: ownerID))
        } catch {
            if isUnknownItem(error) { return }
            throw error
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
}

actor CloudKitSidecarPhotoWorker {
    static let shared = CloudKitSidecarPhotoWorker()

    @discardableResult
    func upload(kind: CloudKitSidecarPhotoKind, ownerID: UUID, fileURL: URL) async -> Bool {
        do {
            try await CloudKitSidecarPhotoStore.upload(kind: kind, ownerID: ownerID, fileURL: fileURL)
            log("upload OK \(kind.recordName(ownerID: ownerID))")
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
