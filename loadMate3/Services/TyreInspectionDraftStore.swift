import Foundation
import UIKit

struct TyreInspectionDraftPhoto: Codable, Equatable {
    var fileName: String
    var kindRaw: String
}

struct TyreInspectionDraft: Codable, Equatable {
    var inspectionDate: Date
    var pressure: String
    var treadDepth: String
    var hasCuts: Bool
    var hasBulges: Bool
    var hasCracking: Bool
    var hasUnevenWear: Bool
    var hasEmbeddedObjects: Bool
    var valveAppearsSound: Bool
    var wheelNutsChecked: Bool
    var overallConditionRaw: String
    var notes: String
    var photos: [TyreInspectionDraftPhoto]

    var overallCondition: TyreCondition {
        TyreCondition(rawValue: overallConditionRaw) ?? .good
    }

    var hasContent: Bool {
        let trimmedPressure = pressure.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTread = treadDepth.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedPressure.isEmpty
            || !trimmedTread.isEmpty
            || hasCuts
            || hasBulges
            || hasCracking
            || hasUnevenWear
            || hasEmbeddedObjects
            || !valveAppearsSound
            || !wheelNutsChecked
            || overallCondition != .good
            || !trimmedNotes.isEmpty
            || !photos.isEmpty
            || !Calendar.current.isDateInToday(inspectionDate)
    }
}

enum TyreInspectionDraftStore {
    private static let subdirectoryName = "TyreInspectionDrafts"
    private static let jpegQuality: CGFloat = 0.8
    private static let defaults = UserDefaults.standard

    static func defaultsKey(for tyreID: UUID) -> String {
        "tyreInspectionDraft.\(tyreID.uuidString)"
    }

    static func load(for tyreID: UUID) -> TyreInspectionDraft? {
        guard let data = defaults.data(forKey: defaultsKey(for: tyreID)) else { return nil }
        return try? JSONDecoder().decode(TyreInspectionDraft.self, from: data)
    }

    static func save(
        _ draft: TyreInspectionDraft,
        images: [(UIImage, TyrePhotoKind)],
        for tyreID: UUID
    ) {
        var persisted = draft
        persisted.photos = writePhotos(images, for: tyreID)

        guard persisted.hasContent else {
            clear(for: tyreID)
            return
        }

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: defaultsKey(for: tyreID))
    }

    static func loadPhotos(for tyreID: UUID, from draft: TyreInspectionDraft) -> [(UIImage, TyrePhotoKind)] {
        draft.photos.compactMap { photo in
            guard let kind = TyrePhotoKind(rawValue: photo.kindRaw) else { return nil }
            guard let url = try? fileURL(tyreID: tyreID, fileName: photo.fileName),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                return nil
            }
            return (image, kind)
        }
    }

    static func clear(for tyreID: UUID) {
        defaults.removeObject(forKey: defaultsKey(for: tyreID))
        if let directory = try? directoryURL(tyreID: tyreID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func writePhotos(
        _ images: [(UIImage, TyrePhotoKind)],
        for tyreID: UUID
    ) -> [TyreInspectionDraftPhoto] {
        let directory: URL
        do {
            directory = try directoryURL(tyreID: tyreID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var kept: [TyreInspectionDraftPhoto] = []
        for (index, entry) in images.enumerated() {
            let prepared = TyrePhotoStore.resize(image: entry.0, maxDimension: 2048)
            guard let data = prepared.jpegData(compressionQuality: jpegQuality) else { continue }
            let fileName = "\(index)-\(entry.1.rawValue).jpg"
            let url = directory.appendingPathComponent(fileName)
            do {
                try data.write(to: url, options: .atomic)
                kept.append(TyreInspectionDraftPhoto(fileName: fileName, kindRaw: entry.1.rawValue))
            } catch {
                continue
            }
        }

        let keepNames = Set(kept.map(\.fileName))
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing where !keepNames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        return kept
    }

    private static func directoryURL(tyreID: UUID) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(subdirectoryName, isDirectory: true)
            .appendingPathComponent(tyreID.uuidString, isDirectory: true)
    }

    private static func fileURL(tyreID: UUID, fileName: String) throws -> URL {
        try directoryURL(tyreID: tyreID).appendingPathComponent(fileName)
    }
}
