import Foundation
import SwiftData

enum TyreStore {
    static func activeRecords(for profile: VehicleProfile?, from allRecords: [TyreRecord]) -> [TyreRecord] {
        guard let profile else { return [] }
        return allRecords
            .filter { $0.vehicleID == profile.id && $0.isCurrentlyFitted }
            .sorted(by: positionSort)
    }

    static func activeRecords(for profile: VehicleProfile?, in context: ModelContext) -> [TyreRecord] {
        guard let profile else { return [] }
        let descriptor = FetchDescriptor<TyreRecord>()
        let all = (try? context.fetch(descriptor)) ?? []
        return activeRecords(for: profile, from: all)
    }

    /// Replaced or otherwise unfitted tyres for a vehicle, newest removal first.
    static func archivedRecords(for profile: VehicleProfile?, from allRecords: [TyreRecord]) -> [TyreRecord] {
        guard let profile else { return [] }
        return allRecords
            .filter { $0.vehicleID == profile.id && !$0.isCurrentlyFitted }
            .sorted(by: removalSort)
    }

    /// Earlier tyres at the same vehicle position as `record` (for example after Replace tyre).
    static func previousRecords(for record: TyreRecord, from allRecords: [TyreRecord]) -> [TyreRecord] {
        allRecords
            .filter {
                $0.id != record.id
                    && $0.vehicleID == record.vehicleID
                    && $0.position == record.position
                    && $0.isSpare == record.isSpare
                    && !$0.isCurrentlyFitted
            }
            .sorted(by: removalSort)
    }

    static func previousRecords(for record: TyreRecord, in context: ModelContext) -> [TyreRecord] {
        let all = (try? context.fetch(FetchDescriptor<TyreRecord>())) ?? []
        return previousRecords(for: record, from: all)
    }

    private static func positionSort(_ lhs: TyreRecord, _ rhs: TyreRecord) -> Bool {
        TyrePosition.allCases.firstIndex(of: lhs.position) ?? 0
            < TyrePosition.allCases.firstIndex(of: rhs.position) ?? 0
    }

    private static func removalSort(_ lhs: TyreRecord, _ rhs: TyreRecord) -> Bool {
        (lhs.removedDate ?? lhs.updatedAt) > (rhs.removedDate ?? rhs.updatedAt)
    }

    static func createLayout(
        for profile: VehicleProfile,
        layout: TyreLayout,
        includeSpare: Bool,
        in context: ModelContext
    ) {
        let existing = activeRecords(for: profile, in: context)
        let targetPositions = Set(TyreSupport.positions(for: layout, includeSpare: includeSpare))

        for record in existing where !targetPositions.contains(record.position) {
            record.isCurrentlyFitted = false
            record.removedDate = Date()
            record.updatedAt = Date()
        }

        let existingPositions = Set(existing.map(\.position))
        for position in targetPositions where !existingPositions.contains(position) {
            context.insert(TyreRecord(vehicleID: profile.id, position: position))
        }

        try? context.save()
    }

    static func replaceTyre(
        _ record: TyreRecord,
        copyManufacturerAndModel: Bool,
        in context: ModelContext
    ) -> TyreRecord {
        record.isCurrentlyFitted = false
        record.removedDate = Date()
        record.updatedAt = Date()

        let replacement = TyreRecord(vehicleID: record.vehicleID, position: record.position, isSpare: record.isSpare)
        replacement.recommendedPressurePSI = record.recommendedPressurePSI
        replacement.tyreSize = record.tyreSize
        replacement.loadIndex = record.loadIndex
        replacement.speedRating = record.speedRating
        if copyManufacturerAndModel {
            replacement.manufacturer = record.manufacturer
            replacement.modelName = record.modelName
        }
        context.insert(replacement)
        try? context.save()
        return replacement
    }

    static func addInspection(
        to record: TyreRecord,
        inspectionDate: Date,
        pressurePSI: Double?,
        treadDepthMM: Double?,
        hasCuts: Bool,
        hasBulges: Bool,
        hasCracking: Bool,
        hasUnevenWear: Bool,
        hasEmbeddedObjects: Bool,
        valveAppearsSound: Bool?,
        wheelNutsChecked: Bool?,
        overallCondition: TyreCondition,
        notes: String,
        in context: ModelContext
    ) -> TyreInspection {
        let inspection = TyreInspection(tyreRecord: record, inspectionDate: inspectionDate)
        inspection.pressurePSI = pressurePSI
        inspection.treadDepthMM = treadDepthMM
        inspection.hasCuts = hasCuts
        inspection.hasBulges = hasBulges
        inspection.hasCracking = hasCracking
        inspection.hasUnevenWear = hasUnevenWear
        inspection.hasEmbeddedObjects = hasEmbeddedObjects
        inspection.valveAppearsSound = valveAppearsSound
        inspection.wheelNutsChecked = wheelNutsChecked
        inspection.overallCondition = overallCondition
        inspection.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        TyreSupport.rollLatestInspection(inspection, into: record)
        context.insert(inspection)
        try? context.save()
        return inspection
    }

    static func suggestedLayout(for records: [TyreRecord], kind: VehicleKind) -> TyreLayout? {
        let positions = Set(records.filter(\.isCurrentlyFitted).map(\.position))
        switch kind {
        case .caravan:
            if positions.contains(.caravanFrontLeft) || positions.contains(.caravanRearLeft) {
                return .caravanTwinAxle
            }
            if positions.contains(.caravanLeft) || positions.contains(.caravanRight) {
                return .caravanSingleAxle
            }
        case .motorhome:
            if positions.contains(.motorhomeRearLeftInner) || positions.contains(.motorhomeRearRightInner) {
                return .motorhomeSixWheel
            }
            if positions.contains(.motorhomeFrontLeft) || positions.contains(.motorhomeRearLeft) {
                return .motorhomeFourWheel
            }
        }
        return nil
    }

    /// Copies plate tyre size / recommended pressure onto fitted positions.
    /// Creates a default layout when none exists so plate values are not discarded.
    @discardableResult
    static func applyPlateTyreSpec(
        to profile: VehicleProfile,
        tyreSize: String?,
        recommendedPressurePSI: Double?,
        in context: ModelContext
    ) -> Int {
        let trimmedSize = tyreSize?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSize = !(trimmedSize ?? "").isEmpty
        let hasPressure = (recommendedPressurePSI ?? 0) > 0
        guard hasSize || hasPressure else { return 0 }

        var records = activeRecords(for: profile, in: context)
        if records.isEmpty {
            let layout = TyreSupport.layoutOptions(for: profile.kind).first
                ?? (profile.kind == .caravan ? .caravanSingleAxle : .motorhomeFourWheel)
            createLayout(for: profile, layout: layout, includeSpare: true, in: context)
            records = activeRecords(for: profile, in: context)
        }

        var updated = 0
        for record in records {
            var didChange = false
            if hasSize, let trimmedSize {
                record.tyreSize = trimmedSize
                didChange = true
            }
            if hasPressure, let recommendedPressurePSI {
                record.recommendedPressurePSI = recommendedPressurePSI
                didChange = true
            }
            if didChange {
                record.updatedAt = Date()
                updated += 1
            }
        }

        if updated > 0 {
            try? context.save()
        }
        return updated
    }

    /// Writes tyre-detail editor fields onto the record.
    /// Incomplete or invalid date codes are left unchanged unless `requireValidDateCode` is true.
    @discardableResult
    static func applyEditorDetails(
        to record: TyreRecord,
        manufacturer: String,
        modelName: String,
        tyreSize: String,
        loadIndex: String,
        speedRating: String,
        dateCode: String,
        recommendedPressureDisplay: String,
        latestPressureDisplay: String,
        latestPressureDate: Date,
        notes: String,
        installedDate: Date,
        removedDate: Date,
        isCurrentlyFitted: Bool,
        pressureUnit: PressureUnit,
        requireValidDateCode: Bool,
        in context: ModelContext
    ) -> TyreDetailsApplyResult {
        let trimmedDateCode = dateCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedDateCode = trimmedDateCode.isEmpty ? nil : TyreSupport.parseDateCode(trimmedDateCode)

        if !trimmedDateCode.isEmpty, parsedDateCode == nil, requireValidDateCode {
            return .blockedByInvalidDateCode
        }

        record.manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        record.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.tyreSize = tyreSize.trimmingCharacters(in: .whitespacesAndNewlines)
        record.loadIndex = loadIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        record.speedRating = speedRating.trimmingCharacters(in: .whitespacesAndNewlines)
        record.recommendedPressurePSI = parsedPressurePSI(recommendedPressureDisplay, unit: pressureUnit)
        record.latestPressurePSI = parsedPressurePSI(latestPressureDisplay, unit: pressureUnit)
        record.latestPressureDate = record.latestPressurePSI == nil ? nil : latestPressureDate
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.installedDate = installedDate
        record.removedDate = isCurrentlyFitted ? nil : removedDate
        record.isCurrentlyFitted = isCurrentlyFitted

        let skippedInvalidDateCode = !trimmedDateCode.isEmpty && parsedDateCode == nil
        if !skippedInvalidDateCode {
            if let parsedDateCode {
                record.dateCode = parsedDateCode.normalized
                record.manufactureWeek = parsedDateCode.week
                record.manufactureYear = parsedDateCode.year
                record.manufactureDate = parsedDateCode.manufactureDate
            } else {
                record.dateCode = ""
                record.manufactureWeek = nil
                record.manufactureYear = nil
                record.manufactureDate = nil
            }
        }

        record.updatedAt = Date()
        try? context.save()
        return skippedInvalidDateCode ? .savedSkippingInvalidDateCode : .saved
    }

    private static func parsedPressurePSI(_ input: String, unit: PressureUnit) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayValue = Double(trimmed) else { return nil }
        return TyreSupport.convertPressure(displayValue, from: unit, to: .psi)
    }
}

enum TyreDetailsApplyResult: Equatable {
    case saved
    case savedSkippingInvalidDateCode
    case blockedByInvalidDateCode
}
