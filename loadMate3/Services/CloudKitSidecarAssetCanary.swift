import CloudKit
import Foundation

/// Sync Debug test 34: upload a tiny JPEG as a standalone `CKAsset` (not SwiftData).
/// Proves whether CloudKit assets work outside `NSPersistentCloudKitContainer`.
enum CloudKitSidecarAssetCanary {
    static let recordType = "LyneqoSidecarPhotoCanary"
    static let recordName = "lyneqo-sidecar-photo-canary"
    static let assetField = "jpeg"
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
        let database = container.privateCloudDatabase
        let recordID = CKRecord.ID(recordName: recordName)

        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                return """
                34. Sidecar CKAsset Canary
                Failed: iCloud account is not available (\(status.rawValue)).
                Sign in on this device and try again.
                """
            }

            try? await database.deleteRecord(withID: recordID)

            let record = CKRecord(recordType: recordType, recordID: recordID)
            record[markerField] = markerValue as CKRecordValue
            record[byteCountField] = NSNumber(value: jpeg.count)
            record[assetField] = CKAsset(fileURL: fileURL)

            let saved = try await database.save(record)
            let fetched = try await database.record(for: saved.recordID)
            let downloaded = readAssetBytes(from: fetched[assetField] as? CKAsset)

            var deleted = "not attempted"
            do {
                try await database.deleteRecord(withID: saved.recordID)
                deleted = "yes"
            } catch {
                deleted = "failed — \(error.localizedDescription)"
            }

            let downloadLine: String
            if let downloaded {
                downloadLine = downloaded == jpeg.count
                    ? "Download: OK (\(downloaded) bytes)"
                    : "Download: size mismatch (uploaded \(jpeg.count), fetched \(downloaded))"
            } else {
                downloadLine = "Download: no asset bytes on fetched record"
            }

            return """
            34. Sidecar CKAsset Canary
            Result: OK
            Record type: \(recordType)
            Record name: \(saved.recordID.recordName)
            Zone: \(saved.recordID.zoneID.zoneName)
            JPEG bytes: \(jpeg.count)
            \(downloadLine)
            Deleted canary record: \(deleted)
            If this is OK, CloudKit assets work outside SwiftData. Photo sharing can use a sidecar CKAsset store.
            """
        } catch {
            let flattened = CloudSyncErrorFormatting.flatten(error).joined(separator: "\n")
            let schemaHint = schemaHint(for: error)
            return """
            34. Sidecar CKAsset Canary
            Result: FAILED
            Record type: \(recordType)
            JPEG bytes: \(jpeg.count)
            \(flattened)
            \(schemaHint)
            If this is the same empty CKError 2 as SwiftData test 18, CloudKit ASSET itself is the break — use iCloud Drive instead of a sidecar.
            """
        }
    }

    private static func readAssetBytes(from asset: CKAsset?) -> Int? {
        guard let url = asset?.fileURL,
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return nil
        }
        return data.count
    }

    private static func schemaHint(for error: Error) -> String {
        let nsError = error as NSError
        let codes: [Int] = {
            var values = [nsError.code]
            if let ckError = error as? CKError, let partial = ckError.partialErrorsByItemID {
                values.append(contentsOf: partial.values.map { ($0 as NSError).code })
            }
            return values
        }()
        if codes.contains(CKError.Code.unknownItem.rawValue)
            || codes.contains(CKError.Code.invalidArguments.rawValue) {
            return """
            Schema hint: this record type may not exist in this CloudKit environment. Run 34 on an Xcode/simulator Development build first so the type can be created, then in CloudKit Console deploy the Development schema to Production before retrying on TestFlight.
            """
        }
        return "Schema hint: none — this does not look like a missing record type."
    }
}
