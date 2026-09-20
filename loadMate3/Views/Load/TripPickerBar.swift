import SwiftUI
import SwiftData

struct TripPickerBar: View {
    @Environment(\.modelContext) private var modelContext

    let profile: VehicleProfile
    let trips: [Trip]
    let activeTrip: Trip?

    @Binding var showAddTrip: Bool
    @Binding var tripPendingRename: Trip?
    @Binding var tripRenameField: String
    var onOpenTripNotes: ((Trip) -> Void)? = nil

    private var canDeleteActiveTrip: Bool {
        trips.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: AppScreenMetrics.smallSpacing) {
                AppSectionHeading("Loading Configuration")
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let trip = activeTrip, let onOpenTripNotes {
                    TripNotesToolbarButton(profile: profile, trip: trip) {
                        onOpenTripNotes(trip)
                    }
                }

                Menu {
                    Button {
                        showAddTrip = true
                    } label: {
                        Label("New Loading Configuration", systemImage: "plus.circle")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Add Loading Configuration")
                .pointerHelp("New Loading Configuration")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppScreenMetrics.smallSpacing) {
                    ForEach(trips) { trip in
                        tripChip(trip)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, AppScreenMetrics.horizontalPadding)
        .padding(.top, AppScreenMetrics.smallSpacing)
        .padding(.bottom, AppScreenMetrics.controlSpacing)
    }

    @ViewBuilder
    private func tripChip(_ trip: Trip) -> some View {
        let isActive = trip.id == activeTrip?.id

        Button {
            TripStore.setActive(trip, on: profile, in: modelContext)
        } label: {
            HStack(spacing: 6) {
                Text(trip.name)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                if trip.hasLoadingNotes(for: profile.kind) {
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.9) : Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.accentColor : LyneqoTheme.card)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onOpenTripNotes {
                Button {
                    onOpenTripNotes(trip)
                } label: {
                    Label("Loading notes", systemImage: "note.text")
                }
            }

            if isActive {
                Button {
                    tripPendingRename = trip
                    tripRenameField = trip.name
                } label: {
                    Label("Rename Loading Configuration", systemImage: "pencil")
                }

                if canDeleteActiveTrip {
                    Button(role: .destructive) {
                        TripStore.deleteTrip(trip, from: profile, in: modelContext)
                    } label: {
                        Label("Delete Loading Configuration", systemImage: "trash")
                    }
                }
            }
        }
        .accessibilityLabel("\(trip.name)\(isActive ? ", selected" : "")")
        .accessibilityHint(isActive ? "Long press for rename or delete" : "Double tap to switch to this loading configuration")
    }
}

// MARK: - Add trip sheet

struct AddTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let profile: VehicleProfile
    @Binding var name: String
    var onCreated: () -> Void = {}

    @Query private var allLoadedItems: [LoadedItem]
    @State private var copyFromTripID: UUID?

    private var previousTrips: [Trip] {
        TripStore.sortedTrips(for: profile)
    }

    private var selectedSource: Trip? {
        previousTrips.first { $0.id == copyFromTripID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppLabeledTextField(
                        "Loading configuration name",
                        placeholder: "e.g., Beach, Grandkids, Europe",
                        text: $name
                    )

                    if !previousTrips.isEmpty {
                        copyFromPreviousSection
                    }

                    AppPrimaryButton("Create Loading Configuration") {
                        createConfiguration()
                    }
                    .padding(.top, AppScreenMetrics.tinySpacing)
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .scrollDismissesKeyboard(.interactively)
            .appScreenBackground()
            .navigationTitle("New Loading Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var copyFromPreviousSection: some View {
        AppSettingsSection(
            "Copy items from previous loading",
            caption: "Choose Default from previous loadings to copy every item, quantity, and location into this new configuration."
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                copySourceRow(title: "Don't copy", subtitle: "Start with an empty load list.", tripID: nil)

                ForEach(previousTrips) { trip in
                    copySourceRow(
                        title: TripStore.copyForwardPickerTitle(for: trip),
                        subtitle: copySourceSubtitle(for: trip),
                        tripID: trip.id
                    )
                }
            }
        }
    }

    private func copySourceRow(title: String, subtitle: String, tripID: UUID?) -> some View {
        let isSelected = copyFromTripID == tripID
        return Button {
            copyFromTripID = tripID
        } label: {
            HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppScreenMetrics.smallSpacing)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func copySourceSubtitle(for trip: Trip) -> String {
        let count = TripStore.loadedItems(for: trip, from: allLoadedItems)
            .filter { $0.quantity > 0 && $0.item != nil }
            .count
        if count == 0 {
            return "No items to copy."
        }
        return count == 1 ? "Copies 1 item." : "Copies \(count) items."
    }

    private func createConfiguration() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = TripStore.addTrip(
            name: trimmed,
            to: profile,
            copyLoadedItemsFrom: selectedSource,
            in: modelContext
        )
        onCreated()
        dismiss()
    }
}
