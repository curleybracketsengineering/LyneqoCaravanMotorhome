import Foundation
import SwiftData

/// Merges duplicate vehicle profiles that appear when iCloud sync combines pre-sync
/// data from multiple devices (same or equivalent name, different record IDs).
enum VehicleProfileSyncReconciliation {
    @MainActor
    @discardableResult
    static func reconcile(in context: ModelContext, appState: AppState) -> Bool {
        let profiles = fetchProfiles(in: context)
        let clusters = Dictionary(grouping: profiles, by: duplicateClusterKey(for:))
        var didChange = false

        for (_, cluster) in clusters where cluster.count > 1 {
            let canonicalID = canonicalProfileID(for: cluster[0].kind)
            let sorted = cluster.sorted {
                retentionScore(
                    for: $0,
                    canonicalID: canonicalID,
                    activeProfileID: appState.activeProfileID
                ) > retentionScore(
                    for: $1,
                    canonicalID: canonicalID,
                    activeProfileID: appState.activeProfileID
                )
            }
            guard let winner = sorted.first else { continue }

            for loser in sorted.dropFirst() {
                SyncDebugLogger.shared.record(
                    category: "startup",
                    message: "[migration] merged duplicate VehicleProfile \(loser.id.uuidString) into \(winner.id.uuidString) (local merge, not a CloudKit import)"
                )
                mergeProfile(loser, into: winner, appState: appState, in: context)
                VehiclePlatePhotoStore.deleteFiles(forVehicleID: loser.id)
                CloudKitSidecarPhotoSync.shared.deletePlate(profileID: loser.id)
                context.delete(loser)
                didChange = true
            }

            winner.sortOrder = min(winner.sortOrder, cluster.map(\.sortOrder).min() ?? winner.sortOrder)
            if cluster.contains(where: { isFactoryDefaultFamilyName($0) }) {
                appState.didSeedDefaultProfiles = true
            }
        }

        let currentProfiles = fetchProfiles(in: context)
        if recoverOrphanedVehicleScopedRecords(
            in: context,
            profiles: currentProfiles,
            activeProfileID: appState.activeProfileID
        ) {
            didChange = true
        }

        if didChange {
            if appState.activeProfileID == nil {
                appState.activeProfileID = VehicleProfileStore.sortedProfiles(fetchProfiles(in: context)).first?.id
            }
            save(context)
        }

        return didChange
    }

    /// Exact factory names before the user renames (e.g. first launch seed).
    static func isFactoryDefaultName(_ profile: VehicleProfile) -> Bool {
        isFactoryDefaultBaseName(normalizedName(profile.name), kind: profile.kind)
    }

    /// Default names and numbered variants such as "My Caravan1" from sync collisions.
    static func isFactoryDefaultFamilyName(_ profile: VehicleProfile) -> Bool {
        let base = baseNameWithoutNumericSuffix(normalizedName(profile.name))
        return isFactoryDefaultBaseName(base, kind: profile.kind)
    }

    static func duplicateClusterKey(for profile: VehicleProfile) -> String {
        let normalized = normalizedName(profile.name)
        let base = baseNameWithoutNumericSuffix(normalized)
        if isFactoryDefaultBaseName(base, kind: profile.kind) {
            return "\(profile.kind.rawValue):default:\(base)"
        }
        return "\(profile.kind.rawValue):exact:\(normalized)"
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func baseNameWithoutNumericSuffix(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression)
    }

    private static func isFactoryDefaultBaseName(_ base: String, kind: VehicleKind) -> Bool {
        switch kind {
        case .caravan:
            return base == "my caravan" || base == "caravan"
        case .motorhome:
            return base == "my motorhome" || base == "motorhome"
        }
    }

    private static func canonicalProfileID(for kind: VehicleKind) -> UUID {
        switch kind {
        case .caravan: return LoadMateSyncIDs.defaultCaravanProfile
        case .motorhome: return LoadMateSyncIDs.defaultMotorhomeProfile
        }
    }

    private static func retentionScore(
        for profile: VehicleProfile,
        canonicalID: UUID,
        activeProfileID: UUID?
    ) -> Int {
        var score = 0
        if profile.id == canonicalID { score += 10_000 }
        if profile.id == activeProfileID { score += 5_000 }
        if profile.isConfiguredForWeightCalculations { score += 1_000 }
        if profile.hasAppliedStarterKit { score += 500 }

        let loadedItemCount = profile.tripsList.reduce(0) { $0 + $1.loadedItemsList.count }
        score += loadedItemCount * 10
        score += profile.tripsList.count * 5

        if profile.weighbridgeWeightKg > 0 { score += 2 }
        if profile.baseWeightKg > 0 { score += 2 }
        if profile.mtplmKg > 0 { score += 2 }
        if profile.carMaxTowBallKg > 0 || profile.maxFrontAxleKg > 0 { score += 2 }

        let tripsWithNotes = profile.tripsList.filter { $0.hasLoadingNotes(for: profile.kind) }
        score += tripsWithNotes.count * 3

        return score
    }

    @MainActor
    private static func mergeProfile(
        _ source: VehicleProfile,
        into target: VehicleProfile,
        appState: AppState,
        in context: ModelContext
    ) {
        mergeSettings(from: source, into: target)

        if source.hasAppliedStarterKit {
            target.hasAppliedStarterKit = true
        }

        var targetTripsByName = Dictionary(
            uniqueKeysWithValues: target.tripsList.map {
                ($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0)
            }
        )

        for trip in source.tripsList {
            let key = trip.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let existingTrip = targetTripsByName[key] {
                for item in trip.loadedItemsList {
                    item.trip = existingTrip
                }
                context.delete(trip)
            } else {
                trip.profile = target
                let nextOrder = (target.tripsList.map(\.sortOrder).max() ?? -1) + 1
                trip.sortOrder = nextOrder
                targetTripsByName[key] = trip
            }
        }

        if let defaultTrip = TripStore.sortedTrips(for: target).first {
            let legacyItems = (try? context.fetch(FetchDescriptor<LoadedItem>()))?
                .filter { $0.trip == nil && $0.profile?.id == source.id } ?? []
            for item in legacyItems {
                item.trip = defaultTrip
                item.profile = nil
            }
        }

        reassignVehicleScopedRecords(from: source.id, to: target.id, in: context)

        if target.checklistSectionsList.isEmpty {
            for section in source.checklistSectionsList {
                section.profile = target
            }
        }

        if appState.activeProfileID == source.id {
            appState.activeProfileID = target.id
        }

        if target.activeTripID == nil, let sourceTripID = source.activeTripID,
           target.tripsList.contains(where: { $0.id == sourceTripID }) {
            target.activeTripID = sourceTripID
        }
    }

    /// Documents, maintenance, warranty and similar records key off `vehicleID`.
    /// Without this, iCloud profile merges hide them from the surviving vehicle.
    @discardableResult
    static func reassignVehicleScopedRecords(
        from oldID: UUID,
        to newID: UUID,
        in context: ModelContext
    ) -> Bool {
        guard oldID != newID else { return false }
        var didChange = false

        for document in fetch(DocumentRecord.self, in: context) where document.vehicleID == oldID {
            document.vehicleID = newID
            didChange = true
        }
        for record in fetch(MaintenanceRecord.self, in: context) where record.vehicleID == oldID {
            record.vehicleID = newID
            didChange = true
        }
        for record in fetch(FaultRecord.self, in: context) where record.vehicleID == oldID {
            record.vehicleID = newID
            didChange = true
        }
        for attachment in fetch(MaintenanceAttachment.self, in: context) where attachment.vehicleID == oldID {
            MaintenanceAttachmentStore.reassign(attachment, to: newID)
            didChange = true
        }
        for plan in fetch(WarrantyPlan.self, in: context) where plan.vehicleID == oldID {
            plan.vehicleID = newID
            didChange = true
        }
        for event in fetch(WarrantyEvent.self, in: context) where event.vehicleID == oldID {
            event.vehicleID = newID
            didChange = true
        }
        for tyre in fetch(TyreRecord.self, in: context) where tyre.vehicleID == oldID {
            for photo in tyre.photos ?? [] {
                TyrePhotoStore.reassign(photo, from: oldID, to: newID)
            }
            tyre.vehicleID = newID
            didChange = true
        }
        for accident in fetch(AccidentRecord.self, in: context) where accident.vehicleID == oldID {
            accident.vehicleID = newID
            didChange = true
        }
        for photo in fetch(AccidentPhoto.self, in: context) where photo.vehicleID == oldID {
            AccidentPhotoStore.reassign(photo, to: newID)
            didChange = true
        }

        return didChange
    }

    /// Picks up documents left on a deleted duplicate vehicle after an earlier merge.
    @discardableResult
    static func recoverOrphanedVehicleScopedRecords(
        in context: ModelContext,
        profiles: [VehicleProfile],
        activeProfileID: UUID?
    ) -> Bool {
        let validIDs = Set(profiles.map(\.id))
        guard !validIDs.isEmpty else { return false }
        var didChange = false

        let events = fetch(WarrantyEvent.self, in: context)
        let documents = fetch(DocumentRecord.self, in: context)

        for document in documents where !validIDs.contains(document.vehicleID) {
            if let event = events.first(where: {
                validIDs.contains($0.vehicleID) && $0.linkedDocumentIDs.contains(document.id)
            }) {
                document.vehicleID = event.vehicleID
                didChange = true
                continue
            }
            if let ownerID = document.attachmentsList.first(where: { validIDs.contains($0.vehicleID) })?.vehicleID {
                document.vehicleID = ownerID
                didChange = true
            }
        }

        for attachment in fetch(MaintenanceAttachment.self, in: context) {
            let ownerID = attachment.documentRecord?.vehicleID
                ?? attachment.maintenanceRecord?.vehicleID
                ?? attachment.faultRecord?.vehicleID
                ?? attachment.warrantyEvent?.vehicleID
            if let ownerID, attachment.vehicleID != ownerID {
                MaintenanceAttachmentStore.reassign(attachment, to: ownerID)
                didChange = true
            }
        }

        for photo in fetch(AccidentPhoto.self, in: context) {
            if let ownerID = photo.record?.vehicleID, photo.vehicleID != ownerID {
                AccidentPhotoStore.reassign(photo, to: ownerID)
                didChange = true
            }
        }

        let leftoverIDs = Set(
            documents.map(\.vehicleID)
                + fetch(MaintenanceRecord.self, in: context).map(\.vehicleID)
                + fetch(WarrantyPlan.self, in: context).map(\.vehicleID)
        ).subtracting(validIDs)

        if leftoverIDs.count == 1,
           let oldID = leftoverIDs.first,
           let newID = adoptionTarget(profiles: profiles, activeProfileID: activeProfileID) {
            if reassignVehicleScopedRecords(from: oldID, to: newID, in: context) {
                didChange = true
            }
        }

        return didChange
    }

    private static func adoptionTarget(
        profiles: [VehicleProfile],
        activeProfileID: UUID?
    ) -> UUID? {
        if profiles.count == 1 { return profiles[0].id }
        let configured = profiles.filter(\.isConfiguredForWeightCalculations)
        if configured.count == 1 { return configured[0].id }
        if let activeProfileID,
           configured.count <= 1,
           let active = profiles.first(where: { $0.id == activeProfileID }),
           configured.isEmpty || configured.contains(where: { $0.id == active.id }) {
            return active.id
        }
        return nil
    }

    private static func fetch<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) -> [Model] {
        (try? context.fetch(FetchDescriptor<Model>())) ?? []
    }

    private static func mergeSettings(from source: VehicleProfile, into target: VehicleProfile) {
        if target.vinChassisNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sourceVIN = source.vinChassisNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceVIN.isEmpty {
                target.vinChassisNumber = sourceVIN
            }
        }
        if target.bodyCellNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sourceCell = source.bodyCellNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceCell.isEmpty {
                target.bodyCellNumber = sourceCell
            }
        }
        if target.registrationMark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sourceRegistration = source.registrationMark.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceRegistration.isEmpty {
                target.registrationMark = sourceRegistration
            }
        }
        if target.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sourceManufacturer = source.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceManufacturer.isEmpty {
                target.manufacturer = sourceManufacturer
            }
        }
        if target.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sourceModel = source.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceModel.isEmpty {
                target.modelName = sourceModel
            }
        }
        VehiclePlatePhotoStore.transferIfNeeded(from: source, to: target)
        if target.firstRegistrationYear == nil, let sourceYear = source.firstRegistrationYear {
            target.firstRegistrationYear = sourceYear
        }
        if target.lastMotDate == nil, let sourceLastMOT = source.lastMotDate {
            target.lastMotDate = sourceLastMOT
        }
        if target.motExpiryDate == nil, let sourceExpiry = source.motExpiryDate {
            target.motExpiryDate = sourceExpiry
        }
        if target.wheelNutTorqueSteelNm == 0, source.wheelNutTorqueSteelNm > 0 {
            target.wheelNutTorqueSteelNm = source.wheelNutTorqueSteelNm
        }
        if target.wheelNutTorqueAlloyNm == 0, source.wheelNutTorqueAlloyNm > 0 {
            target.wheelNutTorqueAlloyNm = source.wheelNutTorqueAlloyNm
        }
        if target.wheelNutTorqueNm == 0, source.wheelNutTorqueNm > 0 {
            target.wheelNutTorqueNm = source.wheelNutTorqueNm
        }
        if target.fittedWheelMaterialRaw.isEmpty, !source.fittedWheelMaterialRaw.isEmpty {
            target.fittedWheelMaterialRaw = source.fittedWheelMaterialRaw
        }
        if target.baseWeightKg == 0, source.baseWeightKg > 0 { target.baseWeightKg = source.baseWeightKg }
        if target.weighbridgeWeightKg == 0, source.weighbridgeWeightKg > 0 {
            target.weighbridgeWeightKg = source.weighbridgeWeightKg
        }
        if target.mtplmKg == 0, source.mtplmKg > 0 { target.mtplmKg = source.mtplmKg }
        if target.gtwKg == 0, source.gtwKg > 0 { target.gtwKg = source.gtwKg }
        if target.caravanMaxNoseKg == 0, source.caravanMaxNoseKg > 0 {
            target.caravanMaxNoseKg = source.caravanMaxNoseKg
        }
        if target.carMaxTowBallKg == 0, source.carMaxTowBallKg > 0 {
            target.carMaxTowBallKg = source.carMaxTowBallKg
        }
        if target.weighbridgeFrontAxleKg == 0, source.weighbridgeFrontAxleKg > 0 {
            target.weighbridgeFrontAxleKg = source.weighbridgeFrontAxleKg
        }
        if target.weighbridgeRearAxleKg == 0, source.weighbridgeRearAxleKg > 0 {
            target.weighbridgeRearAxleKg = source.weighbridgeRearAxleKg
        }
        if target.maxFrontAxleKg == 0, source.maxFrontAxleKg > 0 {
            target.maxFrontAxleKg = source.maxFrontAxleKg
        }
        if target.maxRearAxleKg == 0, source.maxRearAxleKg > 0 {
            target.maxRearAxleKg = source.maxRearAxleKg
        }
        if target.maxGarageKg == 0, source.maxGarageKg > 0 { target.maxGarageKg = source.maxGarageKg }
        if target.maxTowBarKg == 0, source.maxTowBarKg > 0 { target.maxTowBarKg = source.maxTowBarKg }

        if !target.hasBikeRack, source.hasBikeRack { target.hasBikeRack = source.hasBikeRack }
        if !target.garageLimitIncludesBikeRack, source.garageLimitIncludesBikeRack {
            target.garageLimitIncludesBikeRack = source.garageLimitIncludesBikeRack
        }
        if !target.usesManualTowBarLoad, source.usesManualTowBarLoad {
            target.usesManualTowBarLoad = source.usesManualTowBarLoad
        }
    }

    private static func fetchProfiles(in context: ModelContext) -> [VehicleProfile] {
        (try? context.fetch(FetchDescriptor<VehicleProfile>())) ?? []
    }

    private static func save(_ context: ModelContext) {
        _ = SyncDebugSaveHelper.save(context, source: "VehicleProfileSyncReconciliation.save")
    }
}
