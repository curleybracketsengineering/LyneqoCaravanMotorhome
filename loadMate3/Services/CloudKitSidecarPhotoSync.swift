import Foundation
import SwiftData
import Combine

/// Queues sidecar CloudKit photo uploads/downloads without putting bytes on SwiftData.
@MainActor
final class CloudKitSidecarPhotoSync: ObservableObject {
    static let shared = CloudKitSidecarPhotoSync()

    @Published private(set) var revision = 0

    private var inFlight = Set<String>()
    private var nextRetryAt: [String: Date] = [:]

    private init() {}

    func uploadAttachment(_ attachment: MaintenanceAttachment) {
        uploadIfFileExists(kind: .attachmentFile, ownerID: attachment.id) {
            try? MaintenanceAttachmentStore.fileURL(
                vehicleID: attachment.vehicleID,
                fileName: attachment.localFileName
            )
        }
        if let thumbnailFileName = attachment.thumbnailFileName {
            uploadIfFileExists(kind: .attachmentThumbnail, ownerID: attachment.id) {
                try? MaintenanceAttachmentStore.fileURL(
                    vehicleID: attachment.vehicleID,
                    fileName: thumbnailFileName
                )
            }
        }
    }

    func downloadAttachmentIfNeeded(_ attachment: MaintenanceAttachment) {
        downloadIfMissing(
            kind: .attachmentFile,
            ownerID: attachment.id,
            fileName: attachment.localFileName
        ) {
            try? MaintenanceAttachmentStore.fileURL(
                vehicleID: attachment.vehicleID,
                fileName: attachment.localFileName
            )
        }
        if let thumbnailFileName = attachment.thumbnailFileName {
            downloadIfMissing(
                kind: .attachmentThumbnail,
                ownerID: attachment.id,
                fileName: thumbnailFileName
            ) {
                try? MaintenanceAttachmentStore.fileURL(
                    vehicleID: attachment.vehicleID,
                    fileName: thumbnailFileName
                )
            }
        }
    }

    func deleteAttachment(id: UUID, includingThumbnail: Bool) {
        enqueueDelete(kind: .attachmentFile, ownerID: id)
        if includingThumbnail {
            enqueueDelete(kind: .attachmentThumbnail, ownerID: id)
        }
    }

    func uploadPlate(_ profile: VehicleProfile) {
        uploadIfFileExists(kind: .plate, ownerID: profile.id) {
            try? VehiclePlatePhotoStore.fileURL(
                vehicleID: profile.id,
                fileName: profile.manufacturerPlatePhotoFileName
            )
        }
    }

    func downloadPlateIfNeeded(_ profile: VehicleProfile) {
        downloadIfMissing(
            kind: .plate,
            ownerID: profile.id,
            fileName: profile.manufacturerPlatePhotoFileName
        ) {
            try? VehiclePlatePhotoStore.fileURL(
                vehicleID: profile.id,
                fileName: profile.manufacturerPlatePhotoFileName
            )
        }
    }

    func deletePlate(profileID: UUID) {
        enqueueDelete(kind: .plate, ownerID: profileID)
    }

    func uploadAccidentPhoto(_ photo: AccidentPhoto) {
        uploadIfFileExists(kind: .accident, ownerID: photo.id) {
            try? AccidentPhotoStore.fileURL(
                vehicleID: photo.vehicleID,
                fileName: photo.localFileName
            )
        }
    }

    func downloadAccidentPhotoIfNeeded(_ photo: AccidentPhoto) {
        downloadIfMissing(
            kind: .accident,
            ownerID: photo.id,
            fileName: photo.localFileName
        ) {
            try? AccidentPhotoStore.fileURL(
                vehicleID: photo.vehicleID,
                fileName: photo.localFileName
            )
        }
    }

    func deleteAccidentPhoto(id: UUID) {
        enqueueDelete(kind: .accident, ownerID: id)
    }

    func uploadTyrePhoto(_ photo: TyrePhoto, vehicleID: UUID) {
        uploadIfFileExists(kind: .tyre, ownerID: photo.id) {
            try? TyrePhotoStore.fileURL(vehicleID: vehicleID, fileName: photo.localFileName)
        }
    }

    func downloadTyrePhotoIfNeeded(_ photo: TyrePhoto, vehicleID: UUID) {
        downloadIfMissing(
            kind: .tyre,
            ownerID: photo.id,
            fileName: photo.localFileName
        ) {
            try? TyrePhotoStore.fileURL(vehicleID: vehicleID, fileName: photo.localFileName)
        }
    }

    func deleteTyrePhoto(id: UUID) {
        enqueueDelete(kind: .tyre, ownerID: id)
    }

    func reconcile(in context: ModelContext, includeUploads: Bool) {
        guard CloudKitSidecarPhotoRuntime.isEnabled else { return }
        nextRetryAt.removeAll()

        if let profiles = try? context.fetch(FetchDescriptor<VehicleProfile>()) {
            for profile in profiles {
                if includeUploads { uploadPlate(profile) }
                downloadPlateIfNeeded(profile)
            }
        }
        if let attachments = try? context.fetch(FetchDescriptor<MaintenanceAttachment>()) {
            for attachment in attachments {
                if includeUploads { uploadAttachment(attachment) }
                downloadAttachmentIfNeeded(attachment)
            }
        }
        if let photos = try? context.fetch(FetchDescriptor<AccidentPhoto>()) {
            for photo in photos {
                if includeUploads { uploadAccidentPhoto(photo) }
                downloadAccidentPhotoIfNeeded(photo)
            }
        }
        if let photos = try? context.fetch(FetchDescriptor<TyrePhoto>()) {
            for photo in photos {
                guard let vehicleID = photo.tyreRecord?.vehicleID else { continue }
                if includeUploads { uploadTyrePhoto(photo, vehicleID: vehicleID) }
                downloadTyrePhotoIfNeeded(photo, vehicleID: vehicleID)
            }
        }
    }

    func reconcileDownloads(in context: ModelContext) {
        reconcile(in: context, includeUploads: false)
    }

    private func uploadIfFileExists(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        url: @escaping () -> URL?
    ) {
        guard CloudKitSidecarPhotoRuntime.isEnabled else { return }
        let key = "up-\(kind.recordName(ownerID: ownerID))"
        if let notBefore = nextRetryAt[key], notBefore > Date() { return }
        guard let initialURL = url(), FileManager.default.fileExists(atPath: initialURL.path) else { return }
        guard inFlight.insert(key).inserted else { return }
        Task {
            defer { inFlight.remove(key) }
            for attempt in 0..<8 {
                guard let fileURL = url(), FileManager.default.fileExists(atPath: fileURL.path) else { return }
                let ok = await CloudKitSidecarPhotoWorker.shared.upload(
                    kind: kind,
                    ownerID: ownerID,
                    fileURL: fileURL
                )
                if ok {
                    nextRetryAt.removeValue(forKey: key)
                    return
                }
                let seconds = min(2 * (attempt + 1), 15)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            nextRetryAt[key] = Date().addingTimeInterval(30)
        }
    }

    private func downloadIfMissing(
        kind: CloudKitSidecarPhotoKind,
        ownerID: UUID,
        fileName: String,
        url: @escaping () -> URL?
    ) {
        guard CloudKitSidecarPhotoRuntime.isEnabled else { return }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = url(), FileManager.default.fileExists(atPath: existing.path) { return }
        let key = kind.recordName(ownerID: ownerID)
        if let notBefore = nextRetryAt[key], notBefore > Date() { return }
        guard inFlight.insert(key).inserted else { return }
        Task {
            defer { inFlight.remove(key) }
            for attempt in 0..<8 {
                guard let destination = url() else { return }
                if FileManager.default.fileExists(atPath: destination.path) { return }
                let ok = await CloudKitSidecarPhotoWorker.shared.download(
                    kind: kind,
                    ownerID: ownerID,
                    destinationURL: destination
                )
                if ok {
                    nextRetryAt.removeValue(forKey: key)
                    revision += 1
                    return
                }
                let seconds = min(2 * (attempt + 1), 15)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            nextRetryAt[key] = Date().addingTimeInterval(30)
        }
    }

    private func enqueueDelete(kind: CloudKitSidecarPhotoKind, ownerID: UUID) {
        guard CloudKitSidecarPhotoRuntime.isEnabled else { return }
        let key = kind.recordName(ownerID: ownerID)
        nextRetryAt[key] = Date().addingTimeInterval(24 * 60 * 60)
        Task {
            await CloudKitSidecarPhotoWorker.shared.delete(kind: kind, ownerID: ownerID)
        }
    }
}
