import SwiftUI
import SwiftData

struct HomeView: View {
    var onNavigateToLoad: (() -> Void)?
    var onNavigateToSummary: (() -> Void)?
    var onNavigateToSafety: (() -> Void)?
    var onNavigateToCare: (() -> Void)?
    var onNavigateToMaintenance: (() -> Void)?
    var onNavigateToTyreSafety: (() -> Void)?
    var onNavigateToWarranty: (() -> Void)?
    var onNavigateToIncidents: (() -> Void)?
    var onNavigateToTrips: (() -> Void)?

    @Environment(\.usePadLayout) private var usePadLayout
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var allLoadedItems: [LoadedItem]
    @StateObject private var viewModel = SummaryViewModel()

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

    private var refreshToken: String {
        let tripSignature = activeTrip.map { "\($0.id)-\($0.name)" } ?? "no-trip"
        let itemSignature = profileLoadedItems.map { "\($0.id.uuidString)-\($0.quantity)" }.joined(separator: "|")
        return "\(tripSignature)|\(itemSignature)"
    }

    var body: some View {
        if usePadLayout {
            HomeDashboardPadView(
                onNavigateToLoad: onNavigateToLoad,
                onNavigateToSafety: onNavigateToSafety,
                onNavigateToCare: onNavigateToCare
            )
        } else {
            phoneBody
        }
    }

    private var phoneBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
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
                        if profile.kind == .caravan, let summary = viewModel.caravanSummary {
                            CaravanHitchHeroView(
                                profile: profile,
                                summary: summary,
                                maxHeight: 200
                            )
                        }

                        LoadOverviewCard(
                            profile: profile,
                            caravanSummary: viewModel.caravanSummary,
                            motorhomeSummary: viewModel.motorhomeSummary,
                            onViewFullSummary: onNavigateToSummary
                        )
                    } else {
                        setupCard
                    }

                    quickActionsSection
                    moreSection
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddTrip = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Add Loading Configuration")
                }
            }
            .task(id: refreshToken) {
                viewModel.refresh(profile: activeProfile, trip: activeTrip, loadedItems: profileLoadedItems)
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
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            Text("Load Overview")
                .font(.headline.weight(.semibold))
            Text(activeProfile?.weightCalculationSetupSummaryMessage
                 ?? "Add a vehicle in Settings to see weight calculations.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSupporting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(LyneqoTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous)
                .strokeBorder(LyneqoTheme.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            Text("Quick Actions")
                .font(.headline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppScreenMetrics.controlSpacing), count: 3), spacing: AppScreenMetrics.controlSpacing) {
                HomeQuickActionButton(title: "Loading", systemImage: "slider.horizontal.3", tint: AppColors.orange) {
                    onNavigateToLoad?()
                }
                HomeQuickActionButton(title: "Trips", systemImage: "suitcase.fill", tint: AppColors.teal) {
                    onNavigateToTrips?()
                }
                HomeQuickActionButton(title: "Incidents", systemImage: "exclamationmark.triangle.fill", tint: AppColors.red) {
                    onNavigateToIncidents?()
                }
            }
        }
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            Text("More")
                .font(.headline.weight(.semibold))

            moreHubGroup(
                title: "Maintenance",
                subtitle: "Services, checks and history",
                systemImage: "wrench.and.screwdriver.fill",
                tint: AppColors.blue
            ) {
                onNavigateToMaintenance?()
            }

            if activeProfile.map({ WarrantySupport.showsWarrantyFeatures(for: $0) }) ?? false {
                moreHubGroup(
                    title: "Warranty",
                    subtitle: "Plans, checks and documents",
                    systemImage: "shield.fill",
                    tint: AppColors.purple
                ) {
                    onNavigateToWarranty?()
                }
            }

            moreHubGroup(
                title: "Tyre Safety",
                subtitle: "Pressures, age and condition",
                systemImage: "circle.circle.fill",
                tint: AppColors.green
            ) {
                onNavigateToTyreSafety?()
            }
        }
    }

    private func moreHubGroup(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        HomeHubListRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            action: action
        )
        .background(LyneqoTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .strokeBorder(LyneqoTheme.border, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }
}
