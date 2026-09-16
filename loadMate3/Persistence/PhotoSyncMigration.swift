import Foundation
import SwiftData

/// Shared helpers for photo and attachment bytes that must stay off CloudKit records.
enum PhotoSyncSupport {
    static func nonEmpty(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    static func fileData(
        vehicleID: UUID,
        fileName: String,
        fileURL: (UUID, String) throws -> URL
    ) -> Data? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = try? fileURL(vehicleID, trimmed),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return nonEmpty(data)
    }

    /// Moves a sidecar file from one vehicle folder to another after a profile merge.
    static func moveFile(
        fromVehicle oldID: UUID,
        toVehicle newID: UUID,
        fileName: String,
        fileURL: (UUID, String) throws -> URL
    ) {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldID != newID, !trimmed.isEmpty else { return }
        guard let source = try? fileURL(oldID, trimmed),
              FileManager.default.fileExists(atPath: source.path),
              let destination = try? fileURL(newID, trimmed) else {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: source)
            return
        }
        try? FileManager.default.moveItem(at: source, to: destination)
    }

    /// Writes `data` to disk when the named file is missing. Creates a UUID file name
    /// when `fileName` is empty. Returns the file name on success.
    static func ensureOnDisk(
        data: Data,
        vehicleID: UUID,
        fileName: String,
        preferredExtension: String,
        fileURL: (UUID, String) throws -> URL
    ) -> String? {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let ext = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        }
        guard let url = try? fileURL(vehicleID, name) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            return name
        }
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}

/// Copies leftover SwiftData/CloudKit photo bytes onto disk, then nils the model
/// fields so CloudKit export is not poisoned by CKAsset payloads.
enum PhotoSyncMigration {
    @MainActor
    @discardableResult
    static func offloadCloudKitAssetBytesIfNeeded(in context: ModelContext) -> Bool {
        var didChange = false

        if let profiles = try? context.fetch(FetchDescriptor<VehicleProfile>()) {
            for profile in profiles {
                if VehiclePlatePhotoStore.offloadCloudKitBytesIfNeeded(for: profile) {
                    didChange = true
                }
            }
        }

        if let photos = try? context.fetch(FetchDescriptor<AccidentPhoto>()) {
            for photo in photos {
                if AccidentPhotoStore.offloadCloudKitBytesIfNeeded(for: photo, vehicleID: photo.vehicleID) {
                    didChange = true
                }
            }
        }

        if let photos = try? context.fetch(FetchDescriptor<TyrePhoto>()) {
            for photo in photos {
                guard let vehicleID = photo.tyreRecord?.vehicleID else { continue }
                if TyrePhotoStore.offloadCloudKitBytesIfNeeded(for: photo, vehicleID: vehicleID) {
                    didChange = true
                }
            }
        }

        if let attachments = try? context.fetch(FetchDescriptor<MaintenanceAttachment>()) {
            for attachment in attachments {
                if MaintenanceAttachmentStore.offloadCloudKitBytesIfNeeded(for: attachment) {
                    didChange = true
                }
            }
        }

        if didChange {
            _ = SyncDebugSaveHelper.save(context, source: "PhotoSyncMigration.offloadCloudKitAssetBytesIfNeeded")
        }
        return didChange
    }
}
