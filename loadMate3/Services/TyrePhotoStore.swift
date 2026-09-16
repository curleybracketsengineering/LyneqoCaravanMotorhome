import Foundation
import SwiftData
import UIKit

enum TyrePhotoStoreError: Error {
    case encodeFailed
}

enum TyrePhotoStore {
    private static let subdirectoryName = "TyrePhotos"
    private static let maxPixelDimension: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.8

    static func directoryURL(vehicleID: UUID) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent(subdirectoryName, isDirectory: true)
            .appendingPathComponent(vehicleID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileURL(vehicleID: UUID, fileName: String) throws -> URL {
        try directoryURL(vehicleID: vehicleID).appendingPathComponent(fileName)
    }

    @discardableResult
    static func save(
        image: UIImage,
        vehicleID: UUID,
        record: TyreRecord,
        inspection: TyreInspection?,
        kind: TyrePhotoKind,
        in context: ModelContext
    ) throws -> TyrePhoto {
        let prepared = resize(image: image, maxDimension: maxPixelDimension)
        guard let data = prepared.jpegData(compressionQuality: jpegQuality) else {
            throw TyrePhotoStoreError.encodeFailed
        }

        let fileName = "\(UUID().uuidString).jpg"
        let url = try fileURL(vehicleID: vehicleID, fileName: fileName)
        try data.write(to: url, options: .atomic)

        let photo = TyrePhoto(
            tyreRecord: record,
            inspection: inspection,
            kind: kind,
            localFileName: fileName
        )
        photo.imageData = nil
        context.insert(photo)
        try context.save()
        CloudKitSidecarPhotoSync.shared.uploadTyrePhoto(photo, vehicleID: vehicleID)
        return photo
    }

    static func savePending(
        images: [(UIImage, TyrePhotoKind)],
        vehicleID: UUID,
        record: TyreRecord,
        inspection: TyreInspection,
        in context: ModelContext
    ) {
        for (image, kind) in images {
            try? save(
                image: image,
                vehicleID: vehicleID,
                record: record,
                inspection: inspection,
                kind: kind,
                in: context
            )
        }
    }

    static func loadData(for photo: TyrePhoto, vehicleID: UUID) -> Data? {
        if let data = loadLocalFileData(for: photo, vehicleID: vehicleID) {
            return data
        }
        CloudKitSidecarPhotoSync.shared.downloadTyrePhotoIfNeeded(photo, vehicleID: vehicleID)
        return PhotoSyncSupport.nonEmpty(photo.imageData)
    }

    static func loadImage(for photo: TyrePhoto, vehicleID: UUID) -> UIImage? {
        guard let data = loadData(for: photo, vehicleID: vehicleID) else { return nil }
        return UIImage(data: data)
    }

    static func loadLocalFileData(for photo: TyrePhoto, vehicleID: UUID) -> Data? {
        PhotoSyncSupport.fileData(
            vehicleID: vehicleID,
            fileName: photo.localFileName,
            fileURL: fileURL
        )
    }

    /// Writes leftover SwiftData bytes to disk, then nils the CloudKit asset field.
    @discardableResult
    static func offloadCloudKitBytesIfNeeded(for photo: TyrePhoto, vehicleID: UUID) -> Bool {
        guard let data = PhotoSyncSupport.nonEmpty(photo.imageData) else {
            return false
        }
        if loadLocalFileData(for: photo, vehicleID: vehicleID) == nil {
            guard let name = PhotoSyncSupport.ensureOnDisk(
                data: data,
                vehicleID: vehicleID,
                fileName: photo.localFileName,
                preferredExtension: "jpg",
                fileURL: fileURL
            ) else {
                return false
            }
            photo.localFileName = name
        }
        photo.imageData = nil
        return true
    }

    static func delete(photo: TyrePhoto, vehicleID: UUID, in context: ModelContext) {
        let photoID = photo.id
        if let url = try? fileURL(vehicleID: vehicleID, fileName: photo.localFileName) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(photo)
        try? context.save()
        CloudKitSidecarPhotoSync.shared.deleteTyrePhoto(id: photoID)
    }

    static func reassign(_ photo: TyrePhoto, from oldVehicleID: UUID, to newVehicleID: UUID) {
        guard oldVehicleID != newVehicleID else { return }
        PhotoSyncSupport.moveFile(
            fromVehicle: oldVehicleID,
            toVehicle: newVehicleID,
            fileName: photo.localFileName,
            fileURL: fileURL
        )
    }

    static func photos(for record: TyreRecord, inspection: TyreInspection?) -> [TyrePhoto] {
        if let inspection {
            return record.photosList.filter { $0.inspection?.id == inspection.id }
        }
        return record.generalPhotosList()
    }

    /// Best photo to show on the vehicle layout diagram — prefers full-tyre shots, then sidewall.
    static func diagramPhoto(for record: TyreRecord) -> TyrePhoto? {
        let photos = photos(for: record, inspection: nil)
        let preferredKinds: [TyrePhotoKind] = [.fullTyre, .sidewall, .general, .tread]
        for kind in preferredKinds {
            if let photo = photos.first(where: { $0.kind == kind }) {
                return photo
            }
        }
        return photos.first
    }

    static func resize(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
