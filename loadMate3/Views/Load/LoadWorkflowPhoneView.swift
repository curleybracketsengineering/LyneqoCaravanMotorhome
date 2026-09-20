import SwiftUI
import SwiftData

struct LoadWorkflowPhoneView: View {
    @Binding var step: LoadWorkflowStep
    var onNavigateToSettings: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var allLoadedItems: [LoadedItem]
    @StateObject private var summaryVM = SummaryViewModel()

    @State private var showAddItem = false
    @State private var showAddTrip = false
    @State private var newTripName = ""
    @State private var tripPendingRename: Trip?
    @State private var tripRenameField = ""

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(profiles: profiles, appState: AppStateStore.canonical(from: appStates))
    }

    private var activeTrip: Trip? {
        TripStore.activeTrip(for: activeProfile)
    }

    private var profileTrips: [Trip] {
        TripStore.sortedTrips(for: activeProfile)
    }

    private var profileLoadedItems: [LoadedItem] {
        TripStore.loadedItems(for: activeTrip, from: allLoadedItems)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                workflowHeader
                    .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                    .padding(.top, AppScreenMetrics.smallSpacing)
                    .padding(.bottom, AppScreenMetrics.controlSpacing)

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .appScreenBackground()
            .navigationTitle("Load")
            .navigationBarTitleDisplayMode(.large)
            .task(id: profileLoadedItems.map(\.id)) {
                summaryVM.refresh(profile: activeProfile, trip: activeTrip, loadedItems: profileLoadedItems)
            }
            .sheet(isPresented: $showAddTrip, onDismiss: { newTripName = "" }) {
                if let profile = activeProfile {
                    AddTripSheet(profile: profile, name: $newTripName) {
                        newTripName = ""
                        showAddTrip = false
                    }
                }
            }
            .alert("Rename Loading Configuration", isPresented: Binding(
                get: { tripPendingRename != nil },
                set: { if !$0 { tripPendingRename = nil } }
            )) {
                TextField("Loading configuration name", text: $tripRenameField)
                Button("Save") {
                    if let trip = tripPendingRename {
                        TripStore.renameTrip(trip, name: tripRenameField, in: modelContext)
                    }
                    tripPendingRename = nil
                }
                Button("Cancel", role: .cancel) { tripPendingRename = nil }
            }
        }
    }

    @ViewBuilder
    private var workflowHeader: some View {
        VStack(spacing: AppScreenMetrics.controlSpacing) {
            LoadWorkflowStepIndicator(step: $step)

            if let profile = activeProfile, !profileTrips.isEmpty {
                HomeTripSelectorBar(
                    profile: profile,
                    trips: profileTrips,
                    activeTrip: activeTrip,
                    showAddTrip: $showAddTrip,
                    tripPendingRename: $tripPendingRename,
                    tripRenameField: $tripRenameField
                )
            }

            if let profile = activeProfile, profile.isConfiguredForWeightCalculations {
                LoadWorkflowMetricsStrip(
                    profile: profile,
                    caravanSummary: summaryVM.caravanSummary,
                    motorhomeSummary: summaryVM.motorhomeSummary
                )
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .items:
            LoadTabContent(
                showAddItem: $showAddItem,
                showsTripPicker: false,
                onNavigateToSettings: onNavigateToSettings
            )
        case .locations:
            LocationView(
                onNavigateToLoad: { step = .items },
                showsTripPicker: false,
                screenTitle: nil
            )
        case .summary:
            ScrollView {
                if let profile = activeProfile {
                    LoadSummaryStepView(
                        profile: profile,
                        trip: activeTrip,
                        caravanSummary: summaryVM.caravanSummary,
                        motorhomeSummary: summaryVM.motorhomeSummary,
                        loadedItems: profileLoadedItems
                    )
                    .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                    .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
                }
            }
        }
    }
}
