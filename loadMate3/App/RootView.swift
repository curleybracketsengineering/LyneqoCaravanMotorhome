import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    @Query private var appStates: [AppState]
    @Query private var profiles: [VehicleProfile]

    @StateObject private var disclaimerVM = DisclaimerViewModel()
    @State private var resolvedState: AppState?

    private var profileListToken: String {
        VehicleProfileStore.uniqueSortedProfiles(profiles)
            .map { "\($0.id.uuidString):\($0.name)" }
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if let state = resolvedState {
                if state.disclaimerAccepted {
                    MainTabView()
                } else {
                    DisclaimerView(appState: state)
                }
            } else {
                ProgressView("Loading..")
            }
        }
        .task(id: "\(appStates.count)-\(profileListToken)") {
            CloudSyncMonitor.shared.attachModelContext(modelContext)
            StartupCensus.log("app launch before startup logic", in: modelContext)
            let state = AppStateStore.resolve(in: modelContext, existing: appStates)
            PhotoSyncMigration.offloadCloudKitAssetBytesIfNeeded(in: modelContext)
            CloudKitSidecarPhotoSync.shared.reconcile(in: modelContext, includeUploads: true)
            let didReconcile = VehicleProfileSyncReconciliation.reconcile(in: modelContext, appState: state)
            if didReconcile {
                SyncDebugLogger.shared.record(
                    category: "startup",
                    message: "[migration] VehicleProfileSyncReconciliation changed local profiles"
                )
            }
            _ = WarrantyStore.mergeDuplicatePlans(in: modelContext)
            resolvedState = disclaimerVM.ensureAppState(in: modelContext, existing: state)
            StartupCensus.log("app launch after startup logic", in: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, resolvedState?.disclaimerAccepted == true else { return }
            CloudKitSidecarPhotoSync.shared.reconcileDownloads(in: modelContext)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(try! LoadMateModelContainer.makePreview())
}
