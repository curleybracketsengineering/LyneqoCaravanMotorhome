import SwiftUI
import SwiftData

enum SafetySegment: String, CaseIterable, Identifiable {
    case today = "Today"
    case checklists = "Checklists"

    var id: String { rawValue }
}

struct SafetyView: View {
    var onNavigateToMaintenance: (() -> Void)?
    var onNavigateToIncidents: (() -> Void)?

    @Environment(\.usePadLayout) private var usePadLayout
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var allLoadedItems: [LoadedItem]
    @Query(sort: \ChecklistSection.sortOrder) private var checklistSections: [ChecklistSection]
    @Query private var tyreRecords: [TyreRecord]
    @StateObject private var summaryVM = SummaryViewModel()

    @State private var segment: SafetySegment = .today
    @State private var showAddTrip = false
    @State private var newTripName = ""
    @State private var tripPendingRename: Trip?
    @State private var tripRenameField = ""
    @State private var showChecklist = false
    @State private var showDepartureChecklist = false
    @State private var showArrivalChecklist = false
    @State private var showStorageChecklist = false
    @State private var showAccidentRecorder = false
    @State private var showIncidentsSheet = false
    @State private var isDimensionsExpanded = false

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

    private var activeTyreRecords: [TyreRecord] {
        TyreStore.activeRecords(for: activeProfile, from: tyreRecords)
    }

    private var todayChecklist: [SafetyCheckItem] {
        SafetySupport.todayChecklist(
            profile: activeProfile,
            caravanSummary: summaryVM.caravanSummary,
            motorhomeSummary: summaryVM.motorhomeSummary,
            checklistSections: ChecklistStore.sections(for: activeProfile, from: checklistSections),
            tyreRecords: activeTyreRecords
        )
    }

    var body: some View {
        if usePadLayout {
            SafetyPadView(onNavigateToMaintenance: onNavigateToMaintenance)
        } else {
            phoneBody
        }
    }

    private var phoneBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    Picker("Safety section", selection: $segment) {
                        ForEach(SafetySegment.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

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

                    switch segment {
                    case .today:
                        todayContent
                    case .checklists:
                        checklistsContent
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Safety")
            .navigationBarTitleDisplayMode(.large)
            .task(id: profileLoadedItems.map(\.id)) {
                summaryVM.refresh(profile: activeProfile, trip: activeTrip, loadedItems: profileLoadedItems)
            }
            .sheet(isPresented: $showChecklist) {
                NavigationStack { ChecklistView() }
            }
            .sheet(isPresented: $showDepartureChecklist) {
                NavigationStack { ChecklistView() }
            }
            .sheet(isPresented: $showArrivalChecklist) {
                NavigationStack { ChecklistView() }
            }
            .sheet(isPresented: $showStorageChecklist) {
                NavigationStack { ChecklistView() }
            }
            .fullScreenCover(isPresented: $showAccidentRecorder) {
                if let profile = activeProfile {
                    AccidentRecorderView(vehicleID: profile.id, profile: profile)
                }
            }
            .sheet(isPresented: $showIncidentsSheet) {
                NavigationStack {
                    AccidentIncidentsView()
                }
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

    private var todayContent: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
            readinessBanner

            if activeProfile != nil {
                accidentControls
            }

            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                Text("Today's Safety Status")
                    .font(.headline.weight(.semibold))

                VStack(spacing: 0) {
                    ForEach(todayChecklist) { item in
                        safetyCheckRow(item)
                        if item.id != todayChecklist.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .padding(AppScreenMetrics.cardInteriorPadding)
                .background(LyneqoTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))

                if tyreChecklistItem?.status == .due {
                    Button {
                        onNavigateToMaintenance?()
                    } label: {
                        HStack {
                            Text("Review tyres")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }

            if let profile = activeProfile {
                vehicleDimensionsSection(profile: profile)
            }

            tyreAlertsCard
        }
    }

    private var readinessBanner: some View {
        let ready = SafetySupport.isReadyToTravel(checklist: todayChecklist)
        return HStack(spacing: AppScreenMetrics.controlSpacing) {
            Image(systemName: ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(ready ? AppColors.green : AppColors.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? "Ready to Travel" : "Action Needed")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ready ? AppColors.green : AppColors.orange)
                Text(ready ? "All critical checks complete" : "\(SafetySupport.dueCount(in: todayChecklist)) checks still due")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
            Spacer()
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background((ready ? AppColors.green : AppColors.orange).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
    }

    private var tyreChecklistItem: SafetyCheckItem? {
        todayChecklist.first { $0.id == "tyre-pressure" }
    }

    private var accidentControls: some View {
        AccidentCompactControls(
            onRecord: { showAccidentRecorder = true },
            onPastIncidents: {
                if let onNavigateToIncidents {
                    onNavigateToIncidents()
                } else {
                    showIncidentsSheet = true
                }
            }
        )
    }

    private func safetyCheckRow(_ item: SafetyCheckItem) -> some View {
        HStack(spacing: AppScreenMetrics.controlSpacing) {
            Image(systemName: item.status == .complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(item.status == .complete ? AppColors.green : AppColors.orange)
            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
            Spacer()
            Text(item.status == .complete ? "Complete" : "Due")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.status == .complete ? AppColors.green : AppColors.orange)
        }
        .padding(.vertical, 6)
    }

    private func quickChecklistRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func vehicleDimensionsSection(profile: VehicleProfile) -> some View {
        let vehicleName = SafetySupport.vehicleKindName(for: profile.kind)
        return AppCollapsibleSettingsSection(
            "Vehicle dimensions",
            caption: "External sizes from your \(vehicleName) handbook — useful for low bridges, ferries, and site access.",
            isExpanded: $isDimensionsExpanded
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                AppLabeledNumberField(
                    "Width (m)",
                    caption: "Widest point including mirrors or awnings if relevant",
                    value: dimensionBinding(for: \.externalWidthM, on: profile),
                    fractionDigitsUpperBound: 2
                )
                AppLabeledNumberField(
                    "Height (m)",
                    caption: "Highest point including roof fittings",
                    value: dimensionBinding(for: \.externalHeightM, on: profile),
                    fractionDigitsUpperBound: 2
                )
                AppLabeledNumberField(
                    "Length (m)",
                    caption: "Overall length including hitch or bike rack if fitted",
                    value: dimensionBinding(for: \.externalLengthM, on: profile),
                    fractionDigitsUpperBound: 2
                )

                AppSectionDivider()

                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    Text("Weight reference")
                        .font(.subheadline.weight(.semibold))
                    Text("From Settings — edit there to update load calculations.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                    dimensionReferenceRow(
                        title: SafetySupport.maxWeightLabel(for: profile.kind),
                        value: profile.mtplmKg > 0 ? Formatters.kg(profile.mtplmKg) : "Not set"
                    )
                    dimensionReferenceRow(
                        title: SafetySupport.unladenWeightLabel(for: profile.kind),
                        value: profile.calculationBaseWeightKg > 0
                            ? Formatters.kg(profile.calculationBaseWeightKg)
                            : "Not set"
                    )
                }
            }
        }
    }

    private func dimensionReferenceRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(value == "Not set" ? AppColors.textSupporting : Color.primary)
        }
    }

    private func dimensionBinding(
        for keyPath: ReferenceWritableKeyPath<VehicleProfile, Double>,
        on profile: VehicleProfile
    ) -> Binding<Double> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in
                profile[keyPath: keyPath] = newValue
                _ = SyncDebugSaveHelper.save(modelContext, source: "SafetyView.saveDimensions")
            }
        )
    }

    private var tyreAlertsCard: some View {
        Button {
            onNavigateToMaintenance?()
        } label: {
            VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
                HStack {
                    Text("Tyre Status")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text("Review tyres")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Label("Oldest tyre: \(SafetySupport.oldestTyreDescription(records: activeTyreRecords))", systemImage: "circle.circle")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                if let tyreItem = tyreChecklistItem {
                    Label(
                        tyreItem.status == .complete ? "Tyre pressures checked" : "Tyre pressures need checking",
                        systemImage: tyreItem.status == .complete ? "checkmark.circle" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(tyreItem.status == .complete ? AppColors.green : AppColors.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppScreenMetrics.cardInteriorPadding)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var checklistsContent: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            Text("Saved checklists for this vehicle.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSupporting)
            quickChecklistRow(title: "Departure checklist", systemImage: "list.clipboard.fill") {
                showDepartureChecklist = true
            }
            quickChecklistRow(
                title: activeProfile?.kind == .motorhome ? "Arrival checklist" : "Arrival / pitching checklist",
                systemImage: "tent.fill"
            ) {
                showArrivalChecklist = true
            }
            quickChecklistRow(title: "Storage checklist", systemImage: "archivebox.fill") {
                showStorageChecklist = true
            }
            AppPrimaryButton("Open full checklist", systemImage: "checklist") {
                showChecklist = true
            }
        }
    }
}
