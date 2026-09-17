import Foundation
import PDFKit
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum MaintenanceAttachmentStoreError: Error {
    case noData
    case unsupportedImage
}

struct MaintenanceAttachmentDraft {
    let data: Data
    let fileType: MaintenanceAttachmentKind
    let preferredFileExtension: String
    let displayName: String
    let utiIdentifier: String
    let pageCount: Int?
    let thumbnailImage: UIImage?
}

enum MaintenanceAttachmentOwner {
    case maintenance(MaintenanceRecord)
    case document(DocumentRecord)
    case fault(FaultRecord)
    case warrantyEvent(WarrantyEvent)

    var vehicleID: UUID {
        switch self {
        case .maintenance(let record): return record.vehicleID
        case .document(let record): return record.vehicleID
        case .fault(let record): return record.vehicleID
        case .warrantyEvent(let event): return event.vehicleID
        }
    }
}

enum MaintenanceAttachmentStore {
    private static let subdirectoryName = "MaintenanceAttachments"
    private static let thumbnailPrefix = "thumb-"
    private static let maxPixelDimension: CGFloat = 2200
    private static let thumbnailMaxDimension: CGFloat = 320
    private static let jpegQuality: CGFloat = 0.82

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
        let directory = try directoryURL(vehicleID: vehicleID)
        return directory.appendingPathComponent(fileName)
    }

    static func draft(
        image: UIImage,
        fileType: MaintenanceAttachmentKind,
        displayName: String
    ) throws -> MaintenanceAttachmentDraft {
        let prepared = resize(image: image, maxDimension: maxPixelDimension)
        guard let data = prepared.jpegData(compressionQuality: jpegQuality) else {
            throw MaintenanceAttachmentStoreError.noData
        }
        let thumbnail = resize(image: prepared, maxDimension: thumbnailMaxDimension)
        return MaintenanceAttachmentDraft(
            data: data,
            fileType: fileType,
            preferredFileExtension: "jpg",
            displayName: displayName,
            utiIdentifier: UTType.jpeg.identifier,
            pageCount: 1,
            thumbnailImage: thumbnail
        )
    }

    static func draft(
        pdfData: Data,
        displayName: String,
        pageCount: Int?,
        fileType: MaintenanceAttachmentKind = .pdf
    ) -> MaintenanceAttachmentDraft {
        let thumbnail = pdfThumbnail(for: pdfData, maxDimension: thumbnailMaxDimension)
        return MaintenanceAttachmentDraft(
            data: pdfData,
            fileType: fileType,
            preferredFileExtension: "pdf",
            displayName: displayName,
            utiIdentifier: UTType.pdf.identifier,
            pageCount: pageCount,
            thumbnailImage: thumbnail
        )
    }

    static func draft(fileAt url: URL) throws -> MaintenanceAttachmentDraft {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let displayName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .data

        if type.conforms(to: .pdf) {
            let pageCount = PDFDocument(data: data)?.pageCount
            return draft(pdfData: data, displayName: displayName, pageCount: pageCount, fileType: .pdf)
        }

        if type.conforms(to: .image), let image = UIImage(data: data) {
            return try draft(image: image, fileType: .photo, displayName: displayName)
        }

        return MaintenanceAttachmentDraft(
            data: data,
            fileType: .file,
            preferredFileExtension: ext,
            displayName: displayName,
            utiIdentifier: type.identifier,
            pageCount: nil,
            thumbnailImage: nil
        )
    }

    @discardableResult
    static func save(
        draft: MaintenanceAttachmentDraft,
        to owner: MaintenanceAttachmentOwner,
        in context: ModelContext
    ) throws -> MaintenanceAttachment {
        let vehicleID = owner.vehicleID
        let fileName = "\(UUID().uuidString).\(draft.preferredFileExtension)"
        let destinationURL = try fileURL(vehicleID: vehicleID, fileName: fileName)
        try draft.data.write(to: destinationURL, options: .atomic)

        var thumbnailFileName: String?
        if let thumbnailImage = draft.thumbnailImage,
           let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.75) {
            let thumbName = "\(thumbnailPrefix)\(UUID().uuidString).jpg"
            let thumbURL = try fileURL(vehicleID: vehicleID, fileName: thumbName)
            try thumbnailData.write(to: thumbURL, options: .atomic)
            thumbnailFileName = thumbName
        }

        let attachment = MaintenanceAttachment(
            vehicleID: vehicleID,
            localFileName: fileName,
            thumbnailFileName: thumbnailFileName,
            fileType: draft.fileType,
            displayName: draft.displayName,
            utiIdentifier: draft.utiIdentifier,
            pageCount: draft.pageCount,
            byteCount: draft.data.count
        )

        switch owner {
        case .maintenance(let record):
            attachment.maintenanceRecord = record
        case .document(let record):
            attachment.documentRecord = record
        case .fault(let record):
            attachment.faultRecord = record
        case .warrantyEvent(let event):
            attachment.warrantyEvent = event
        }

        context.insert(attachment)
        try context.save()
        CloudKitSidecarPhotoSync.shared.uploadAttachment(attachment)
        return attachment
    }

    static func save(drafts: [MaintenanceAttachmentDraft], to owner: MaintenanceAttachmentOwner, in context: ModelContext) {
        for draft in drafts {
            do {
                _ = try save(draft: draft, to: owner, in: context)
            } catch {
                Task { @MainActor in
                    SyncDebugLogger.shared.record(
                        category: "attachment",
                        message: "Failed to save \(draft.displayName) (\(draft.fileType.rawValue), \(draft.data.count) bytes): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    static func reassign(_ attachment: MaintenanceAttachment, to vehicleID: UUID) {
        guard attachment.vehicleID != vehicleID else { return }
        let oldID = attachment.vehicleID
        PhotoSyncSupport.moveFile(
            fromVehicle: oldID,
            toVehicle: vehicleID,
            fileName: attachment.localFileName,
            fileURL: fileURL
        )
        if let thumbnailFileName = attachment.thumbnailFileName {
            PhotoSyncSupport.moveFile(
                fromVehicle: oldID,
                toVehicle: vehicleID,
                fileName: thumbnailFileName,
                fileURL: fileURL
            )
        }
        attachment.vehicleID = vehicleID
    }

    static func loadData(for attachment: MaintenanceAttachment) -> Data? {
        if let data = loadLocalFileData(for: attachment) {
            return data
        }
        CloudKitSidecarPhotoSync.shared.downloadAttachmentIfNeeded(attachment)
        return PhotoSyncSupport.nonEmpty(attachment.fileData)
    }

    static func loadLocalFileData(for attachment: MaintenanceAttachment) -> Data? {
        PhotoSyncSupport.fileData(
            vehicleID: attachment.vehicleID,
            fileName: attachment.localFileName,
            fileURL: fileURL
        )
    }

    static func loadLocalThumbnailData(for attachment: MaintenanceAttachment) -> Data? {
        guard let thumbnailFileName = attachment.thumbnailFileName else { return nil }
        return PhotoSyncSupport.fileData(
            vehicleID: attachment.vehicleID,
            fileName: thumbnailFileName,
            fileURL: fileURL
        )
    }

    /// Writes leftover SwiftData bytes to disk, then nils the CloudKit asset fields.
    @discardableResult
    static func offloadCloudKitBytesIfNeeded(for attachment: MaintenanceAttachment) -> Bool {
        var didChange = false

        if let data = PhotoSyncSupport.nonEmpty(attachment.fileData) {
            if loadLocalFileData(for: attachment) == nil {
                let ext = URL(fileURLWithPath: attachment.localFileName).pathExtension
                guard let name = PhotoSyncSupport.ensureOnDisk(
                    data: data,
                    vehicleID: attachment.vehicleID,
                    fileName: attachment.localFileName,
                    preferredExtension: ext.isEmpty ? "bin" : ext,
                    fileURL: fileURL
                ) else {
                    return didChange
                }
                attachment.localFileName = name
            }
            attachment.fileData = nil
            didChange = true
        }

        if let data = PhotoSyncSupport.nonEmpty(attachment.thumbnailData) {
            if loadLocalThumbnailData(for: attachment) == nil {
                guard let name = PhotoSyncSupport.ensureOnDisk(
                    data: data,
                    vehicleID: attachment.vehicleID,
                    fileName: attachment.thumbnailFileName ?? "",
                    preferredExtension: "jpg",
                    fileURL: fileURL
                ) else {
                    return didChange
                }
                attachment.thumbnailFileName = name
            }
            attachment.thumbnailData = nil
            didChange = true
        }

        return didChange
    }

    static func loadImage(for attachment: MaintenanceAttachment) -> UIImage? {
        guard let data = loadData(for: attachment) else { return nil }
        if attachment.fileType == .pdf {
            return pdfThumbnail(for: data, maxDimension: maxPixelDimension)
        }
        return UIImage(data: data)
    }

    static func loadThumbnail(for attachment: MaintenanceAttachment) -> UIImage? {
        if let data = loadLocalThumbnailData(for: attachment),
           let image = UIImage(data: data) {
            return image
        }
        CloudKitSidecarPhotoSync.shared.downloadAttachmentIfNeeded(attachment)
        if let data = PhotoSyncSupport.nonEmpty(attachment.thumbnailData),
           let image = UIImage(data: data) {
            return image
        }
        if attachment.fileType == .pdf, let data = loadData(for: attachment) {
            return pdfThumbnail(for: data, maxDimension: thumbnailMaxDimension)
        }
        if let image = loadImage(for: attachment) {
            return resize(image: image, maxDimension: thumbnailMaxDimension)
        }
        return nil
    }

    static func delete(_ attachment: MaintenanceAttachment, in context: ModelContext) {
        let attachmentID = attachment.id
        let includingThumbnail = attachment.thumbnailFileName != nil
        if let url = try? fileURL(vehicleID: attachment.vehicleID, fileName: attachment.localFileName) {
            try? FileManager.default.removeItem(at: url)
        }
        if let thumbnailFileName = attachment.thumbnailFileName,
           let thumbURL = try? fileURL(vehicleID: attachment.vehicleID, fileName: thumbnailFileName) {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        context.delete(attachment)
        try? context.save()
        CloudKitSidecarPhotoSync.shared.deleteAttachment(id: attachmentID, includingThumbnail: includingThumbnail)
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

    static func pdfThumbnail(for data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            return nil
        }

        let pageBounds = page.bounds(for: .mediaBox)
        let scale = min(maxDimension / max(pageBounds.width, pageBounds.height), 1)
        let targetSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)

        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: targetSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
    }
}
