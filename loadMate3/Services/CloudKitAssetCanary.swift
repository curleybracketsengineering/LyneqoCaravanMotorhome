import Combine
import Foundation
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Sync Debug tests 18 and 19: write a tiny JPEG attachment and wait for CloudKit export.
/// 18 writes `fileData` only. 19 also writes `thumbnailData` (two assets on one record).
@MainActor
final class CloudKitAssetCanary: ObservableObject {
    static let shared = CloudKitAssetCanary()

    static let documentTitle = "\(CloudKitDiagnosticMarkers.namePrefix) Tiny Asset Canary"
    static let documentOnlyTitle = "\(CloudKitDiagnosticMarkers.namePrefix) Document Canary"
    static let attachmentMetaTitle = "\(CloudKitDiagnosticMarkers.namePrefix) Attachment Meta Canary"
    static let attachmentName = "\(CloudKitDiagnosticMarkers.namePrefix) Tiny JPEG"
    static let attachmentMetaName = "\(CloudKitDiagnosticMarkers.namePrefix) Attachment Meta"

    @Published private(set) var lastReport = "Not run"
    @Published private(set) var isRunning = false

    private init() {}

    func runFileOnlyCanary(in context: ModelContext, monitor: CloudSyncMonitor) async {
        await run(includeThumbnail: false, in: context, monitor: monitor)
    }

    func runThumbnailCanary(in context: ModelContext, monitor: CloudSyncMonitor) async {
        await run(includeThumbnail: true, in: context, monitor: monitor)
    }

    func runDocumentOnlyCanary(in context: ModelContext, monitor: CloudSyncMonitor) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let label = "32. Document Canary (No File)"
        logger("Started \(label)")

        guard let profile = activeProfile(in: context) else {
            finish("Failed: no vehicle selected. Add or select a vehicle first.")
            return
        }

        removePreviousCanaries(in: context)

        let document = DocumentRecord(vehicleID: profile.id)
        document.title = Self.documentOnlyTitle
        document.category = .other
        document.notes = "canary-document-only"
        context.insert(document)

        let started = Date()
        let saved = SyncDebugSaveHelper.save(context, source: "CloudKitAssetCanary.documentOnly")
        guard saved else {
            finish("Failed: local save of canary document did not succeed.")
            return
        }

        logger("Saved document-only canary on \(profile.name) id=\(document.id.uuidString)")
        let exportLine = await waitForExport(after: started, monitor: monitor)
        finish(
            """
            \(label)
            Vehicle: \(profile.name)
            Attachment: none
            Document id: \(document.id.uuidString)
            \(exportLine)
            Diagnostic title: \(Self.documentOnlyTitle)
            If this exports OK, the break is the JPEG asset, not the Care document record.
            """
        )
    }

    func runAttachmentMetaCanary(in context: ModelContext, monitor: CloudSyncMonitor) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let label = "33. Attachment Canary (No Bytes)"
        logger("Started \(label)")

        guard let profile = activeProfile(in: context) else {
            finish("Failed: no vehicle selected. Add or select a vehicle first.")
            return
        }

        removePreviousCanaries(in: context)

        let document = DocumentRecord(vehicleID: profile.id)
        document.title = Self.attachmentMetaTitle
        document.category = .other
        document.notes = "canary-attachment-meta"
        context.insert(document)

        let attachment = MaintenanceAttachment(
            vehicleID: profile.id,
            localFileName: "",
            fileType: .file,
            displayName: Self.attachmentMetaName,
            utiIdentifier: "public.data",
            byteCount: 0
        )
        attachment.fileData = nil
        attachment.thumbnailData = nil
        attachment.documentRecord = document
        context.insert(attachment)

        let started = Date()
        let saved = SyncDebugSaveHelper.save(context, source: "CloudKitAssetCanary.attachmentMeta")
        guard saved else {
            finish("Failed: local save of canary attachment metadata did not succeed.")
            return
        }

        logger("Saved attachment-meta canary on \(profile.name) attachment=\(attachment.id.uuidString)")
        let exportLine = await waitForExport(after: started, monitor: monitor)
        finish(
            """
            \(label)
            Vehicle: \(profile.name)
            fileData: nil
            thumbnailData: nil
            Attachment id: \(attachment.id.uuidString)
            \(exportLine)
            Diagnostic title: \(Self.attachmentMetaTitle)
            If this exports OK, MaintenanceAttachment records are fine and only JPEG/ASSET bytes break export.
            If this fails, the MaintenanceAttachment type itself is the problem.
            """
        )
    }

    static func makeTinyJPEG() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.4) ?? Data()
        #else
        return Data()
        #endif
    }

    private func run(includeThumbnail: Bool, in context: ModelContext, monitor: CloudSyncMonitor) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let label = includeThumbnail ? "19. Tiny Asset Canary With Thumbnail" : "18. Tiny Asset Canary"
        logger("Started \(label)")

        guard let profile = activeProfile(in: context) else {
            finish("Failed: no vehicle selected. Add or select a vehicle first.")
            return
        }

        let jpeg = Self.makeTinyJPEG()
        guard jpeg.count > 0, jpeg.count < 8_192 else {
            finish("Failed: could not build a tiny JPEG (bytes=\(jpeg.count)).")
            return
        }

        removePreviousCanaries(in: context)

        let document = DocumentRecord(vehicleID: profile.id)
        document.title = Self.documentTitle
        document.category = .other
        document.notes = includeThumbnail ? "tiny-asset-canary-thumbnail" : "canary-file-only"
        context.insert(document)

        let attachment = MaintenanceAttachment(
            vehicleID: profile.id,
            localFileName: "canary-\(UUID().uuidString).jpg",
            thumbnailFileName: includeThumbnail ? "thumb-canary-\(UUID().uuidString).jpg" : nil,
            fileType: .photo,
            displayName: Self.attachmentName,
            utiIdentifier: UTType.jpeg.identifier,
            pageCount: 1,
            byteCount: jpeg.count
        )
        attachment.fileData = jpeg
        attachment.thumbnailData = includeThumbnail ? jpeg : nil
        attachment.documentRecord = document
        context.insert(attachment)

        let started = Date()
        let saved = SyncDebugSaveHelper.save(context, source: "CloudKitAssetCanary.run")
        guard saved else {
            finish("Failed: local save of canary attachment did not succeed.")
            return
        }

        logger(
            "Saved canary document on \(profile.name) jpegBytes=\(jpeg.count) thumbnail=\(includeThumbnail ? "yes" : "no") attachment=\(attachment.id.uuidString)"
        )

        let exportLine = await waitForExport(after: started, monitor: monitor)
        let report = """
        \(label)
        Vehicle: \(profile.name)
        JPEG bytes: \(jpeg.count)
        Thumbnail asset: \(includeThumbnail ? "yes (\(jpeg.count) bytes)" : "no")
        Attachment id: \(attachment.id.uuidString)
        \(exportLine)
        Diagnostic title: \(Self.documentTitle)
        If export failed, do not run the other canary. Run 7 then 10 to remove this diagnostic document, or delete it in Care.
        """
        finish(report)
    }

    func runSidecarCKAssetCanary() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        logger("Started 34. Sidecar CKAsset Canary")
        let report = await CloudKitSidecarAssetCanary.run()
        finish(report)
    }

    private func activeProfile(in context: ModelContext) -> VehicleProfile? {
        let profiles = (try? context.fetch(FetchDescriptor<VehicleProfile>())) ?? []
        let states = (try? context.fetch(FetchDescriptor<AppState>())) ?? []
        return VehicleProfileStore.activeProfile(
            profiles: profiles,
            appState: AppStateStore.canonical(from: states)
        )
    }

    private func removePreviousCanaries(in context: ModelContext) {
        let documents = (try? context.fetch(FetchDescriptor<DocumentRecord>())) ?? []
        let titles = [Self.documentTitle, Self.documentOnlyTitle, Self.attachmentMetaTitle]
        for document in documents where titles.contains(document.title) {
            for attachment in document.attachmentsList {
                MaintenanceAttachmentStore.delete(attachment, in: context)
            }
            context.delete(document)
        }
    }

    private func waitForExport(after start: Date, monitor: CloudSyncMonitor, timeout: TimeInterval = 90) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = monitor.lastSyncEvent,
               event.kind == .exportToCloud,
               event.finishedAt > start {
                if event.succeeded {
                    return "CloudKit export: OK @ \(SyncDebugFormatting.string(for: event.finishedAt))"
                }
                let error = event.errorDescription ?? "unknown error"
                return "CloudKit export: FAILED @ \(SyncDebugFormatting.string(for: event.finishedAt)) — \(error)"
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return "CloudKit export: timed out after \(Int(timeout))s waiting for an export event"
    }

    private func finish(_ report: String) {
        lastReport = report
        logger(report)
    }

    private func logger(_ message: String) {
        SyncDebugLogger.shared.record(category: "canary", message: message)
    }
}
