import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LocationView: View {
    var onNavigateToLoad: (() -> Void)?
    var showsTripPicker: Bool = true
    var screenTitle: String? = "Locations"

    @Environment(\.usePadLayout) private var usePadLayout
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\LoadedItem.loadedAt)]) private var allLoadedItems: [LoadedItem]
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]

    @StateObject private var viewModel = LocationViewModel()
    @State private var zonePickerItem: LoadedItem?
    @State private var showLocationsHelp = false
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

    private var loadedItems: [LoadedItem] {
        TripStore.loadedItems(for: activeTrip, from: allLoadedItems)
    }

    private var caravanSummary: WeightSummary? {
        guard let profile = activeProfile, profile.kind == .caravan else { return nil }
        return WeightCalculator.summary(profile: profile, loadedItems: loadedItems)
    }

    private var motorhomeSummary: MotorhomeWeightSummary? {
        guard let profile = activeProfile, profile.kind == .motorhome else { return nil }
        return MotorhomeWeightCalculator.summary(profile: profile, loadedItems: loadedItems, trip: activeTrip)
    }

    private var zoneWeightsKg: [LoadZone: Double] {
        LocationZoneWeights.totals(for: loadedItems, kind: activeProfile?.kind ?? .caravan, profile: activeProfile)
    }

    /// Tow bar is entered per trip on Load; it is not a `LoadedItem` but still belongs on the map.
    private var hasMotorhomeTowBarLoad: Bool {
        guard let profile = activeProfile,
              profile.kind == .motorhome,
              profile.usesManualTowBarLoad else { return false }
        return (activeTrip?.manualTowBarLoadKg ?? 0) > 0
    }

    private var showsLocationWorkspace: Bool {
        !loadedItems.isEmpty || hasMotorhomeTowBarLoad
    }

    var body: some View {
        if usePadLayout {
            LocationPadRedirectView()
        } else {
            phoneBody
        }
    }

    private var phoneBody: some View {
        NavigationStack {
            Group {
                if !showsLocationWorkspace {
                    LocationEmptyStateView(
                        tripName: activeTrip?.name,
                        onAddItems: onNavigateToLoad
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                            if showsTripPicker, let profile = activeProfile, !profileTrips.isEmpty {
                                TripPickerBar(
                                    profile: profile,
                                    trips: profileTrips,
                                    activeTrip: activeTrip,
                                    showAddTrip: $showAddTrip,
                                    tripPendingRename: $tripPendingRename,
                                    tripRenameField: $tripRenameField
                                )
                                .padding(.horizontal, 0)
                            }

                            if let profile = activeProfile {
                                mapAndWeightSection(profile: profile)
                            }

                            if !loadedItems.isEmpty {
                                assignItemsSection
                            }
                        }
                        .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                        .padding(.top, AppScreenMetrics.verticalScreenPadding)
                        .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(LyneqoTheme.background)
            .modifier(OptionalPrincipalTabTitle(title: screenTitle))
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
            .sheet(item: $zonePickerItem) { loaded in
                LocationZonePickerSheet(
                    vehicleKind: activeProfile?.kind ?? .caravan,
                    profile: activeProfile,
                    itemTitle: title(for: loaded),
                    selectedZone: loaded.zone,
                    onSelect: { zone in
                        viewModel.updateZone(for: loaded, to: zone, in: modelContext)
                    }
                )
            }
            .alert("About locations", isPresented: $showLocationsHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(locationsHelpMessage)
            }
        }
    }

    private var locationsHelpMessage: String {
        if activeProfile?.kind == .motorhome {
            return "Cab is ahead of the front axle; Middle between the axles; Rear above the rear; Garage and bike rack behind the rear. Stay within plated axle and garage limits."
        }
        return "Where you place each item shifts estimated tow bar (nose) weight. Front zones tend to increase it; rear zones tend to decrease it. Stay within your car’s tow ball limit."
    }

    // MARK: - Sections

    @ViewBuilder
    private func mapAndWeightSection(profile: VehicleProfile) -> some View {
        let summary = caravanSummary
        let towBarWarning = summary.map { $0.isOverTowBallLimit || $0.isTowVehicleUnsuitable } ?? false

        let mhSummary = motorhomeSummary
        let map = CaravanPositionMapView(
            vehicleKind: profile.kind,
            profile: profile,
            zoneWeightsKg: zoneWeightsKg,
            onDropAssign: { zone, loadedItemID in
                guard let loaded = loadedItems.first(where: { $0.id == loadedItemID }) else { return }
                viewModel.updateZone(for: loaded, to: zone, in: modelContext)
            },
            caravanEstimatedTowBarKg: profile.kind == .caravan ? summary?.estimatedNoseWeightKg : nil,
            caravanTowBarUsesWarningColor: profile.kind == .caravan ? towBarWarning : false,
            motorhomeTowBarLoadKg: profile.kind == .motorhome && profile.usesManualTowBarLoad
                ? mhSummary?.towBarLoadKg
                : nil,
            motorhomeTowBarUsesWarningColor: mhSummary?.isOverTowBarLimit ?? false
        )

        switch profile.kind {
        case .caravan:
            map
        case .motorhome:
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                if let summary = motorhomeSummary {
                    motorhomeAxleEstimateCard(summary: summary, profile: profile)
                }
                map
            }
        }
    }

    private var assignItemsSection: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: AppScreenMetrics.smallSpacing) {
                Text("Assign items to locations")
                    .font(.headline)
                    .foregroundStyle(Color.primary)

                Button {
                    showLocationsHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel("About locations")
                }
                .buttonStyle(.plain)
                .pointerHelp("Help")
                .padding(.top, 2)
            }

            VStack(spacing: 0) {
                ForEach(Array(loadedItems.enumerated()), id: \.element.id) { index, loaded in
                    LocationItemRow(
                        loaded: loaded,
                        title: title(for: loaded),
                        weightLine: weightLine(for: loaded),
                        zone: loaded.zone,
                        vehicleKind: activeProfile?.kind ?? .caravan,
                        onTap: { zonePickerItem = loaded }
                    )

                    if index < loadedItems.count - 1 {
                        Divider()
                            .padding(.leading, AppScreenMetrics.cardInteriorPadding)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                    .fill(LyneqoTheme.card)
            )
        }
    }

    private func motorhomeAxleEstimateCard(summary: MotorhomeWeightSummary, profile: VehicleProfile) -> some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
            Text("Estimated axle loads")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSupporting)

            HStack(spacing: AppScreenMetrics.sectionSpacing) {
                axleColumn(
                    title: "Front",
                    kg: summary.estimatedFrontAxleKg,
                    isOver: summary.isOverFrontAxle
                )
                axleColumn(
                    title: "Rear",
                    kg: summary.estimatedRearAxleKg,
                    isOver: summary.isOverRearAxle
                )
            }

            if profile.monitorsGarageLimit {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.garageLimitIncludesBikeRack ? "Garage + rack load" : "Garage load")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppColors.textSupporting)
                        Text(Formatters.kg(summary.garageLoadedKg))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(summary.isOverGarageLimit ? AppColors.red : Color.primary)
                    }
                    Spacer()
                    Text("max \(Formatters.kg(profile.maxGarageKg))")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                }
            } else if summary.garageLoadedKg > 0 {
                Text("Garage zone: \(Formatters.kg(summary.garageLoadedKg)) — set a max in Settings to monitor")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .fill(LyneqoTheme.card)
        )
    }

    private func axleColumn(title: String, kg: Double, isOver: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColors.textSupporting)
            Text(Formatters.kg(kg))
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(isOver ? AppColors.red : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func title(for loaded: LoadedItem) -> String {
        let name = loaded.item?.name ?? "Unknown item"
        guard let itemId = loaded.item?.id else { return name }
        let sameItem = loadedItems.filter { $0.item?.id == itemId }.sorted { $0.loadedAt < $1.loadedAt }
        guard sameItem.count > 1, let index = sameItem.firstIndex(where: { $0.id == loaded.id }) else {
            return name
        }
        return "\(name) (\(index + 1) of \(sameItem.count))"
    }

    private func weightLine(for loaded: LoadedItem) -> String {
        let unitKg = loaded.item?.weightKg ?? 0
        let totalKg = unitKg * Double(max(loaded.quantity, 0))
        return Formatters.kg(totalKg)
    }
}

// MARK: - Empty state

private struct LocationEmptyStateView: View {
    var tripName: String?
    var onAddItems: (() -> Void)?

    var body: some View {
        VStack(spacing: AppScreenMetrics.fieldSpacing) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: AppScreenMetrics.heroIconSize, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.45))
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Nothing loaded yet")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.primary)

            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppScreenMetrics.sectionSpacingLoose)

            if onAddItems != nil {
                Button("Go to Load") {
                    onAddItems?()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, AppScreenMetrics.smallSpacing)
            }
        }
        .padding(.vertical, AppScreenMetrics.sectionSpacingLoose)
    }

    private var emptyMessage: String {
        if let tripName, !tripName.isEmpty {
            return "No items loaded for “\(tripName)”. Use the Load tab to add items, then assign zones here."
        }
        return "Use the Load tab to add items, then assign each one to a zone here."
    }
}

// MARK: - Item row

private struct LocationItemRow: View {
    let loaded: LoadedItem
    let title: String
    let weightLine: String
    let zone: LoadZone
    let vehicleKind: VehicleKind
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: AppScreenMetrics.controlSpacing) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)

                Text(weightLine)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }

            Spacer(minLength: 0)

            LocationZoneBadge(zone: zone, vehicleKind: vehicleKind)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppScreenMetrics.cardInteriorPadding)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityHint("Opens zone picker")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        // Dragging an item onto a zone updates its `LoadedItem.zone`.
        .draggable(LoadedItemDragPayload(loadedItemID: loaded.id))
    }
}

private struct LocationZoneBadge: View {
    let zone: LoadZone
    let vehicleKind: VehicleKind

    var body: some View {
        if zone == .unassigned {
            Text("Assign")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSupporting)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(LyneqoTheme.softTeal)
                )
        } else {
            Text(zone.locationBadgeTitle(for: vehicleKind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(zone.chipAccentColor(for: vehicleKind))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(zone.chipAccentColor(for: vehicleKind).opacity(0.14))
                )
        }
    }
}

// MARK: - Drag payload

/// Drag payload used to assign a loaded item to a zone by dropping onto the position map.
struct LoadedItemDragPayload: Transferable, Hashable, Codable {
    let loadedItemID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .loadedItem)
    }
}

private extension UTType {
    static let loadedItem: UTType = UTType(exportedAs: "com.loadmate.loaded-item")
}
