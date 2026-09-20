import SwiftUI
import SwiftData

enum LoadPlannerPadTab: String, CaseIterable, Identifiable {
    case items = "Items"
    case locations = "Locations"
    case summary = "Summary"

    var id: String { rawValue }

    var workflowStep: LoadWorkflowStep {
        switch self {
        case .items: return .items
        case .locations: return .locations
        case .summary: return .summary
        }
    }

    static func from(workflowStep: LoadWorkflowStep) -> LoadPlannerPadTab {
        switch workflowStep {
        case .items: return .items
        case .locations: return .locations
        case .summary: return .summary
        }
    }
}

struct LoadPlannerPadView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var tab: LoadPlannerPadTab = .items
    @State private var showAddItem = false
    @State private var showAddTrip = false
    @State private var newTripName = ""
    @State private var tripPendingRename: Trip?
    @State private var tripRenameField = ""

    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var allLoadedItems: [LoadedItem]
    @StateObject private var summaryVM = SummaryViewModel()

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

    private var workflowStepBinding: Binding<LoadWorkflowStep> {
        Binding(
            get: { tab.workflowStep },
            set: { tab = LoadPlannerPadTab.from(workflowStep: $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            plannerChrome
                .padding(.horizontal, PadContentLayout.horizontalGutter)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.controlSpacing)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabFooter
        }
        .appScreenBackground()
        .navigationTitle("Load Planner")
        .task(id: profileLoadedItems.map(\.id)) {
            summaryVM.refresh(profile: activeProfile, trip: activeTrip, loadedItems: profileLoadedItems)
        }
        .task(id: profiles.map(\.id)) {
            TripStore.ensureTripsMigrated(in: modelContext, profiles: profiles)
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

    // MARK: - Chrome

    private var plannerChrome: some View {
        VStack(spacing: AppScreenMetrics.controlSpacing) {
            LoadWorkflowStepIndicator(step: workflowStepBinding)

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

            if let profile = activeProfile {
                LoadWorkflowMetricsStrip(
                    profile: profile,
                    caravanSummary: summaryVM.caravanSummary,
                    motorhomeSummary: summaryVM.motorhomeSummary
                )
            }
        }
        .frame(maxWidth: PadContentLayout.workspaceMaxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .items:
            itemsTab
        case .locations:
            locationsTab
        case .summary:
            summaryTab
        }
    }

    private var itemsTab: some View {
        HStack(spacing: 0) {
            Spacer(minLength: PadContentLayout.horizontalGutter)
            LoadTabContent(
                showAddItem: $showAddItem,
                showsTripPicker: false,
                usesScrollablePanel: true
            )
            .frame(maxWidth: 680)
            .frame(maxHeight: .infinity)
            Spacer(minLength: PadContentLayout.horizontalGutter)
        }
    }

    private var locationsTab: some View {
        PlacementPadPanel(layout: .split, onAddItems: { tab = .items })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryTab: some View {
        HStack(spacing: 0) {
            Spacer(minLength: PadContentLayout.horizontalGutter)

            if let profile = activeProfile {
                HStack(alignment: .top, spacing: AppScreenMetrics.sectionSpacing) {
                    ScrollView {
                        LoadSummaryStepView(
                            profile: profile,
                            trip: activeTrip,
                            caravanSummary: summaryVM.caravanSummary,
                            motorhomeSummary: summaryVM.motorhomeSummary,
                            loadedItems: profileLoadedItems,
                            showsNoseWeightInline: false
                        )
                        .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
                    }
                    .loadPlannerScrollPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if profile.kind == .caravan, let summary = summaryVM.caravanSummary {
                        LoadPlannerNoseGuidePanel(summary: summary, profile: profile)
                            .frame(width: 340)
                            .frame(maxHeight: .infinity)
                    } else if let summary = summaryVM.motorhomeSummary {
                        LoadPlannerMotorhomeGuidePanel(summary: summary, profile: profile)
                            .frame(width: 340)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: PadContentLayout.workspaceMaxWidth)
                .frame(maxHeight: .infinity)
            }

            Spacer(minLength: PadContentLayout.horizontalGutter)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var tabFooter: some View {
        switch tab {
        case .items:
            EmptyView()
        case .locations:
            footerButton("View Summary →") { tab = .summary }
        case .summary:
            EmptyView()
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        AppPrimaryButton(title, action: action)
            .padding(.horizontal, PadContentLayout.horizontalGutter)
            .padding(.vertical, AppScreenMetrics.controlSpacing)
            .frame(maxWidth: PadContentLayout.workspaceMaxWidth)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

// MARK: - Summary side panels

private struct LoadPlannerNoseGuidePanel: View {
    let summary: WeightSummary
    let profile: VehicleProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                Text("Nose Weight Guide")
                    .font(.headline.weight(.semibold))

                ZStack {
                    Image("iphoneCaravan")
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)

                Text(Formatters.kg(summary.estimatedNoseWeightKg))
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Text("Estimated nose weight")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)

                let zoneBounds = summary.noseGaugeZoneBounds(profile: profile)
                NoseWeightSafeZoneGauge(
                    zoneLowKg: zoneBounds.low,
                    zoneHighKg: zoneBounds.high,
                    carMaxTowBallKg: profile.effectiveMaxTowBallKg,
                    estimatedNoseKg: summary.estimatedNoseWeightKg
                )
            }
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous))
        }
        .scrollDismissesKeyboard(.interactively)
        .loadPlannerScrollPanel()
    }
}

private struct LoadPlannerMotorhomeGuidePanel: View {
    let summary: MotorhomeWeightSummary
    let profile: VehicleProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                Text("Axle Overview")
                    .font(.headline.weight(.semibold))

                axleRow(
                    title: "Front axle",
                    current: summary.estimatedFrontAxleKg,
                    limit: profile.maxFrontAxleKg,
                    isOver: summary.isOverFrontAxle
                )
                axleRow(
                    title: "Rear axle",
                    current: summary.estimatedRearAxleKg,
                    limit: profile.maxRearAxleKg,
                    isOver: summary.isOverRearAxle
                )

                if summary.monitorsTowBar {
                    Divider()
                    HStack {
                        Text("Tow bar load")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(Formatters.kg(summary.towBarLoadKg))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(summary.isOverTowBarLimit ? AppColors.red : Color.accentColor)
                    }
                }

                Text("\(Formatters.kg(summary.availableGrossKg)) payload remaining")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous))
        }
        .loadPlannerScrollPanel()
    }

    private func axleRow(title: String, current: Double, limit: Double, isOver: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text("\(Formatters.kg(current)) of \(Formatters.kg(limit))")
                .font(.caption)
                .foregroundStyle(isOver ? AppColors.red : AppColors.textSupporting)
            let fraction = limit > 0 ? min(current / limit, 1) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LyneqoTheme.softTeal)
                    Capsule()
                        .fill(isOver ? AppColors.red : Color.accentColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
    }
}
