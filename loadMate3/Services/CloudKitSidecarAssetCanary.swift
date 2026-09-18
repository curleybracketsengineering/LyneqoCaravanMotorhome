import CloudKit
import Foundation

/// Sync Debug test 34: upload through the real sidecar store, then fetch the bytes back.
/// Uses the same record-name prefix as live plate/tyre/document photos.
enum CloudKitSidecarAssetCanary {
    static let recordType = CloudKitSidecarPhotoSchema.compatible.recordType
    static let recordName = "lyneqo-sidecar-photo-canary"
    static let assetField = CloudKitSidecarPhotoSchema.compatible.assetField
    static let markerField = "marker"
    static let byteCountField = "byteCount"
    static let markerValue = "\(CloudKitDiagnosticMarkers.namePrefix) sidecar-ckasset"

    static func writeTemporaryJPEG(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyneqo-sidecar-canary-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func run(containerID: String = LoadMateModelContainer.cloudKitContainerID) async -> String {
        let jpeg = CloudKitAssetCanary.makeTinyJPEG()
        guard jpeg.count > 0, jpeg.count < 8_192 else {
            return "Failed: could not build a tiny JPEG (bytes=\(jpeg.count))."
        }

        let fileURL: URL
        do {
            fileURL = try writeTemporaryJPEG(jpeg)
        } catch {
            return "Failed: could not write temporary JPEG — \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let container = CKContainer(identifier: containerID)
        let ownerID = UUID()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyneqo-sidecar-canary-download-\(ownerID.uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                return """
                34. Sidecar CKAsset Canary
                Failed: iCloud account is not available (\(status.rawValue)).
                Sign in on this device and try again.
                """
            }

            try await CloudKitSidecarPhotoStore.upload(
                kind: .plate,
                ownerID: ownerID,
                fileURL: fileURL,
                containerID: containerID
            )
            let downloaded = try await CloudKitSidecarPhotoStore.download(
                kind: .plate,
                ownerID: ownerID,
                destinationURL: destination,
                containerID: containerID
            )
            let downloadedBytes = (try? Data(contentsOf: destination))?.count ?? 0

            var deleted = "not attempted"
            do {
                try await CloudKitSidecarPhotoStore.delete(
                    kind: .plate,
                    ownerID: ownerID,
                    containerID: containerID
                )
                deleted = "yes"
            } catch {
                deleted = "failed — \(error.localizedDescription)"
            }

            let downloadLine: String
            if downloaded, downloadedBytes == jpeg.count {
                downloadLine = "Download: OK (\(downloadedBytes) bytes)"
            } else if downloaded {
                downloadLine = "Download: size mismatch (uploaded \(jpeg.count), fetched \(downloadedBytes))"
            } else {
                downloadLine = "Download: sidecar record was not readable after upload"
            }

            return """
            34. Sidecar CKAsset Canary
            Result: \(downloaded && downloadedBytes == jpeg.count ? "OK" : "FAILED")
            Preferred type: \(CloudKitSidecarPhotoSchema.preferred.recordType) field=\(CloudKitSidecarPhotoSchema.preferred.assetField)
            Compatible type: \(CloudKitSidecarPhotoSchema.compatible.recordType) field=\(CloudKitSidecarPhotoSchema.compatible.assetField)
            Record name: \(CloudKitSidecarPhotoKind.plate.recordName(ownerID: ownerID))
            JPEG bytes: \(jpeg.count)
            \(downloadLine)
            Deleted canary record: \(deleted)
            This tests the same upload/download path used by plates, tyres and document files.
            """
        } catch {
            let flattened = CloudSyncErrorFormatting.flatten(error).joined(separator: "\n")
            let schemaHint = schemaHint(for: error)
            return """
            34. Sidecar CKAsset Canary
            Result: FAILED
            Preferred type: \(CloudKitSidecarPhotoSchema.preferred.recordType)
            Compatible type: \(CloudKitSidecarPhotoSchema.compatible.recordType)
            JPEG bytes: \(jpeg.count)
            \(flattened)
            \(schemaHint)
            If this is the same empty CKError 2 as SwiftData test 18, CloudKit ASSET itself is the break — use iCloud Drive instead of a sidecar.
            """
        }
    }

    private static func schemaHint(for error: Error) -> String {
        if CloudKitSidecarPhotoStore.isSchemaError(error) {
            return """
            Schema hint: neither sidecar record type saved in this CloudKit environment. Run 34 on an Xcode Development build first so the type can be created, then in CloudKit Console deploy the Development schema to Production before retrying on TestFlight.
            """
        }
        return "Schema hint: none — this does not look like a missing record type."
    }
}
