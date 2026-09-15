import Foundation
import SwiftData

enum VehicleProfileStore {
    static func sortedProfiles(_ profiles: [VehicleProfile]) -> [VehicleProfile] {
        profiles.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// One row per profile ID — avoids duplicate list rows during CloudKit import.
    static func uniqueSortedProfiles(_ profiles: [VehicleProfile]) -> [VehicleProfile] {
        var seen = Set<UUID>()
        return sortedProfiles(profiles).filter { seen.insert($0.id).inserted }
    }

    static func activeProfile(
        profiles: [VehicleProfile],
        appState: AppState?
    ) -> VehicleProfile? {
        let ordered = sortedProfiles(profiles)
        guard !ordered.isEmpty else { return nil }
        if let id = appState?.activeProfileID,
           let match = ordered.first(where: { $0.id == id }) {
            return match
        }
        return ordered.first
    }

    static func setActive(_ profile: VehicleProfile, appState: AppState, in context: ModelContext) {
        appState.activeProfileID = profile.id
        save(context)
    }

    @MainActor
    static func ensureInitialData(
        in context: ModelContext,
        profiles: [VehicleProfile],
        appState: AppState?
    ) -> (profiles: [VehicleProfile], appState: AppState) {
        StartupCensus.log("startup profiles/trips before", in: context)
        let result = ensureInitialDataUnlogged(in: context, profiles: profiles, appState: appState)
        StartupCensus.log("startup profiles/trips after", in: context)
        return result
    }

    @MainActor
    private static func ensureInitialDataUnlogged(
        in context: ModelContext,
        profiles: [VehicleProfile],
        appState: AppState?
    ) -> (profiles: [VehicleProfile], appState: AppState) {
        let state: AppState
        if let appState {
            state = appState
        } else {
            state = AppStateStore.resolve(in: context)
        }

        if !LoadMateSeedPolicy.automaticVehicleAndChecklistSeedEnabled {
            SyncDebugSeedLog.record("[profile-seed] skipped: automatic vehicle seed disabled")
        } else if SyncDebugSeedIsolation.isAutomaticSeedingSuppressed {
            SyncDebugSeedLog.record("[profile-seed] skipped: developer suppression flag is on")
        } else if profiles.isEmpty, !state.didSeedDefaultProfiles {
            SyncDebugSeedLog.record("[profile-seed] creating default vehicle reason = no profile existed")
            let caravan = VehicleProfile(
                id: LoadMateSyncIDs.defaultCaravanProfile,
                name: "My Caravan",
                kind: .caravan,
                sortOrder: 0
            )
            context.insert(caravan)
            SyncDebugSeedLog.record("[seed] created default VehicleProfile id=\(caravan.id.uuidString) reason = no profile existed")
            SyncDebugSeedLog.record("[seed] Creating default trip")
            _ = TripStore.ensureDefaultTrip(
                for: caravan,
                preferredID: LoadMateSyncIDs.defaultCaravanTrip,
                in: context
            )
            _ = LoadMateChecklistSeedTemplate.insertAll(onto: caravan, in: context)

            SyncDebugSeedLog.record("[profile-seed] creating default vehicle reason = paired factory motorhome")
            let motorhome = VehicleProfile(
                id: LoadMateSyncIDs.defaultMotorhomeProfile,
                name: "My Motorhome",
                kind: .motorhome,
                sortOrder: 1
            )
            context.insert(motorhome)
            SyncDebugSeedLog.record("[seed] created default VehicleProfile id=\(motorhome.id.uuidString) reason = paired factory motorhome")
            SyncDebugSeedLog.record("[seed] Creating default trip")
            _ = TripStore.ensureDefaultTrip(
                for: motorhome,
                preferredID: LoadMateSyncIDs.defaultMotorhomeTrip,
                in: context
            )
            _ = LoadMateChecklistSeedTemplate.insertAll(onto: motorhome, in: context)

            state.didSeedDefaultProfiles = true
            setActive(caravan, appState: state, in: context)
            return ([caravan, motorhome], state)
        } else if profiles.isEmpty {
            SyncDebugSeedLog.record("[profile-seed] skipped: existing vehicle found flag already seeded")
        } else {
            SyncDebugSeedLog.record("[profile-seed] skipped: existing vehicle found count=\(profiles.count)")
        }

        if state.activeProfileID == nil, let first = sortedProfiles(profiles).first {
            setActive(first, appState: state, in: context)
        }

        _ = VehicleProfileSyncReconciliation.reconcile(in: context, appState: state)
        let currentProfiles = (try? context.fetch(FetchDescriptor<VehicleProfile>())) ?? profiles

        TripStore.ensureTripsMigrated(in: context, profiles: currentProfiles)
        ChecklistVehicleMigration.migrateIfNeeded(in: context, appState: state, profiles: currentProfiles)
        ChecklistVehicleMigration.patchMotorhomeFactoryItemsIfNeeded(in: context, profiles: currentProfiles)
        ChecklistVehicleMigration.patchCaravanFactoryItemsIfNeeded(in: context, profiles: currentProfiles)

        return (sortedProfiles(currentProfiles), state)
    }

    @MainActor
    static func addProfile(
        name: String,
        kind: VehicleKind,
        profiles: [VehicleProfile],
        appState: AppState,
        in context: ModelContext
    ) -> VehicleProfile {
        let nextOrder = (profiles.map(\.sortOrder).max() ?? -1) + 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = VehicleProfile(
            name: trimmed.isEmpty ? kind.displayName : trimmed,
            kind: kind,
            sortOrder: nextOrder
        )
        context.insert(profile)
        _ = TripStore.ensureDefaultTrip(for: profile, in: context)
        _ = LoadMateChecklistSeedTemplate.insertAll(onto: profile, in: context)
        setActive(profile, appState: appState, in: context)
        return profile
    }

    @MainActor
    static func deleteProfile(
        _ profile: VehicleProfile,
        profiles: [VehicleProfile],
        appState: AppState,
        in context: ModelContext
    ) {
        guard profiles.count > 1 else { return }
        let wasActive = appState.activeProfileID == profile.id
        let profileID = profile.id
        let attachmentIDs = ((try? context.fetch(FetchDescriptor<MaintenanceAttachment>())) ?? [])
            .filter { $0.vehicleID == profileID }
            .map { ($0.id, $0.thumbnailFileName != nil) }
        let accidentIDs = ((try? context.fetch(FetchDescriptor<AccidentPhoto>())) ?? [])
            .filter { $0.vehicleID == profileID }
            .map(\.id)
        let tyreIDs = ((try? context.fetch(FetchDescriptor<TyrePhoto>())) ?? [])
            .filter { $0.tyreRecord?.vehicleID == profileID }
            .map(\.id)
        VehiclePlatePhotoStore.deleteFiles(forVehicleID: profileID)
        CloudKitSidecarPhotoSync.shared.deletePlate(profileID: profileID)
        for (id, includingThumbnail) in attachmentIDs {
            CloudKitSidecarPhotoSync.shared.deleteAttachment(id: id, includingThumbnail: includingThumbnail)
        }
        for id in accidentIDs {
            CloudKitSidecarPhotoSync.shared.deleteAccidentPhoto(id: id)
        }
        for id in tyreIDs {
            CloudKitSidecarPhotoSync.shared.deleteTyrePhoto(id: id)
        }
        context.delete(profile)
        if let counts = CloudSyncMonitor.shared.currentEntityCounts() {
            CloudKitDeletionSyncVerifier.shared.noteLocalDeletion(of: profile.id, counts: counts)
        }
        if wasActive {
            let remaining = profiles.filter { $0.id != profile.id }
            if let next = sortedProfiles(remaining).first {
                setActive(next, appState: appState, in: context)
            } else {
                appState.activeProfileID = nil
            }
        }
        save(context)
    }

    static func loadedItems(for profile: VehicleProfile?, from all: [LoadedItem]) -> [LoadedItem] {
        TripStore.loadedItems(for: TripStore.activeTrip(for: profile), from: all)
    }

    private static func save(_ context: ModelContext) {
        _ = SyncDebugSaveHelper.save(context, source: "VehicleProfileStore.save")
    }
}
