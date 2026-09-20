import SwiftUI
import SwiftData

struct HomeDashboardPadView: View {
    var onNavigateToLoad: (() -> Void)?
    var onNavigateToSafety: (() -> Void)?
    var onNavigateToCare: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var allLoadedItems: [LoadedItem]
    @Query private var maintenanceRecords: [MaintenanceRecord]
    @Query private var documentRecords: [DocumentRecord]
    @Query private var faultRecords: [FaultRecord]
    @Query(sort: \ChecklistSection.sortOrder) private var checklistSections: [ChecklistSection]
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

    private var todayChecklist: [SafetyCheckItem] {
        SafetySupport.todayChecklist(
            profile: activeProfile,
            caravanSummary: viewModel.caravanSummary,
            motorhomeSummary: viewModel.motorhomeSummary,
            checklistSections: ChecklistStore.sections(for: activeProfile, from: checklistSections),
            tyreRecords: []
        )
    }

    private var maintenanceSummary: MaintenanceDashboardSummary {
        guard let profile = activeProfile else {
            return MaintenanceDashboardSummary(
                upcomingTitle: "—",
                upcomingSubtitle: "No vehicle selected",
                outstandingFaults: 0,
                documentCount: 0,
                recentActivityTitle: "—",
                recentActivitySubtitle: ""
            )
        }
        let maintenance = MaintenanceSupport.maintenanceRecords(for: profile.id, from: maintenanceRecords)
        let documents = MaintenanceSupport.documentRecords(for: profile.id, from: documentRecords)
        let faults = MaintenanceSupport.faultRecords(for: profile.id, from: faultRecords)
        return MaintenanceSupport.dashboardSummary(
            maintenanceRecords: maintenance,
            documents: documents,
            faults: faults
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacingLoose) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))

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
                    LoadOverviewCard(
                        profile: profile,
                        caravanSummary: viewModel.caravanSummary,
                        motorhomeSummary: viewModel.motorhomeSummary,
                        onViewFullSummary: onNavigateToLoad
                    )
                }

                HStack(alignment: .top, spacing: AppScreenMetrics.sectionSpacing) {
                    statusCard(
                        title: "Today's Safety Status",
                        value: "\(SafetySupport.completedCount(in: todayChecklist)) complete",
                        subtitle: "\(SafetySupport.dueCount(in: todayChecklist)) due",
                        tint: AppColors.green,
                        action: onNavigateToSafety
                    )
                    statusCard(
                        title: "Maintenance Due",
                        value: maintenanceSummary.upcomingTitle,
                        subtitle: maintenanceSummary.upcomingSubtitle,
                        tint: AppColors.blue,
                        action: onNavigateToCare
                    )
                    if WarrantySupport.showsWarrantyFeatures(for: activeProfile) {
                        statusCard(
                            title: "Warranty Active",
                            value: "Valid",
                            subtitle: maintenanceSummary.recentActivitySubtitle,
                            tint: AppColors.purple,
                            action: onNavigateToCare
                        )
                    }
                }

                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    Text("Quick Actions")
                        .font(.headline.weight(.semibold))
                    HStack(spacing: AppScreenMetrics.controlSpacing) {
                        padQuickAction("Open Load Planner", systemImage: "shippingbox.fill", tint: AppColors.blue, action: onNavigateToLoad)
                        padQuickAction("Start Safety Check", systemImage: "checkmark.shield.fill", tint: AppColors.green, action: onNavigateToSafety)
                        padQuickAction("Record Maintenance", systemImage: "wrench.fill", tint: AppColors.orange, action: onNavigateToCare)
                        padQuickAction("Add Document", systemImage: "doc.badge.plus", tint: AppColors.purple, action: onNavigateToCare)
                    }
                }
            }
            .padding(PadContentLayout.horizontalGutter)
            .padReadableContent(maxWidth: 1_100)
        }
        .appScreenBackground()
        .navigationTitle("Dashboard")
        .task(id: profileLoadedItems.map(\.id)) {
            viewModel.refresh(profile: activeProfile, trip: activeTrip, loadedItems: profileLoadedItems)
        }
        .sheet(isPresented: $showAddTrip, onDismiss: { newTripName = "" }) {
            if let profile = activeProfile {
                AddTripSheet(profile: profile, name: $newTripName) {
                    newTripName = ""
                    showAddTrip = false
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        return "\(salutation), \(activeProfile?.name ?? "there")."
    }

    private func statusCard(title: String, value: String, subtitle: String, tint: Color, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func padQuickAction(_ title: String, systemImage: String, tint: Color, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(spacing: AppScreenMetrics.smallSpacing) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
