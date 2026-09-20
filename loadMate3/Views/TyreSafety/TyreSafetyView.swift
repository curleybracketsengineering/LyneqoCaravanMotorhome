import SwiftUI
import SwiftData

struct TyreSafetyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.usePadLayout) private var usePadLayout
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var tyreRecords: [TyreRecord]

    @State private var selectedRecord: TyreRecord?
    @State private var inspectionRecord: TyreRecord?
    @State private var showSetup = false
    @State private var showHistory = false
    @State private var showInfo = false

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(profiles: profiles, appState: AppStateStore.canonical(from: appStates))
    }

    private var activeRecords: [TyreRecord] {
        TyreStore.activeRecords(for: activeProfile, from: tyreRecords)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = activeProfile {
                    if activeRecords.isEmpty {
                        TyreSafetyEmptyStateView(profile: profile) {
                            showSetup = true
                        }
                    } else {
                        TyreSafetyOverviewView(
                            profile: profile,
                            records: activeRecords,
                            onSelectRecord: { selectedRecord = $0 },
                            onLogPressure: { inspectionRecord = $0 },
                            onShowSetup: { showSetup = true },
                            onShowHistory: { showHistory = true },
                            onShowInfo: { showInfo = true }
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No vehicle selected",
                        systemImage: "car.rear",
                        description: Text("Add or select a caravan or motorhome in Settings to use Tyre Safety.")
                    )
                }
            }
            .appScreenBackground()
            .appPrincipalTabTitle("Tyre Safety")
        }
        .sheet(isPresented: $showSetup) {
            if let profile = activeProfile {
                TyreSetupView(profile: profile, existingRecords: activeRecords)
            }
        }
        .sheet(item: $selectedRecord) { record in
            TyreDetailView(
                record: record,
                siblingRecords: activeRecords.filter { $0.id != record.id }
            )
        }
        .sheet(item: $inspectionRecord) { record in
            if let profile = activeProfile {
                TyreInspectionView(record: record, profile: profile)
            }
        }
        .sheet(isPresented: $showHistory) {
            TyreHistoryView(
                activeRecords: activeRecords,
                archivedRecords: TyreStore.archivedRecords(for: activeProfile, from: tyreRecords)
            )
        }
        .sheet(isPresented: $showInfo) {
            TyreSafetyInfoView()
        }
    }
}

private struct TyreSafetyEmptyStateView: View {
    let profile: VehicleProfile
    let onSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                AppHeroSection(
                    systemImage: "circle.hexagongrid.fill",
                    title: "Set up your tyre layout",
                    subtitle: "Record tyre age, pressure, condition and inspection history for this \(profile.kind.displayName.lowercased())."
                )
                AppPrimaryButton("Set up tyres", systemImage: "plus.circle.fill", action: onSetup)
                WheelNutTorqueSection(profile: profile)
            }
            .padding(.horizontal, AppScreenMetrics.horizontalPadding)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
        }
    }
}

private struct TyreSafetyOverviewView: View {
    @AppStorage(TyreSupport.pressureUnitAppStorageKey) private var pressureUnitRaw = PressureUnit.psi.rawValue

    let profile: VehicleProfile
    let records: [TyreRecord]
    let onSelectRecord: (TyreRecord) -> Void
    let onLogPressure: (TyreRecord) -> Void
    let onShowSetup: () -> Void
    let onShowHistory: () -> Void
    let onShowInfo: () -> Void

    @State private var showActionsNeeded = false
    @State private var pendingRecordSelection: TyreRecord?

    private var pressureUnit: PressureUnit {
        PressureUnit(rawValue: pressureUnitRaw) ?? .psi
    }

    private var actionNeededCount: Int {
        TyreSupport.actionNeededCount(in: records)
    }

    private var recordsNeedingAction: [TyreRecord] {
        records.filter { $0.statusLevel == .action || $0.statusLevel == .attention || $0.statusLevel == .incomplete }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                header

                setupBar

                TyreCardsGrid(
                    records: records,
                    pressureUnit: pressureUnit,
                    onSelectRecord: onSelectRecord,
                    onLogPressure: onLogPressure
                )

                WheelNutTorqueSection(profile: profile)

                quickActionsRow

                recommendedRecordBox
            }
            .padding(.horizontal, AppScreenMetrics.horizontalPadding)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
        }
        .sheet(isPresented: $showActionsNeeded, onDismiss: {
            if let pendingRecordSelection {
                self.pendingRecordSelection = nil
                onSelectRecord(pendingRecordSelection)
            }
        }) {
            TyreActionsNeededSheet(
                records: recordsNeedingAction,
                onSelectRecord: { record in
                    pendingRecordSelection = record
                    showActionsNeeded = false
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
            Text("Age, pressure, condition and replacement planning")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppScreenMetrics.smallSpacing)
            if actionNeededCount > 0 {
                Button {
                    showActionsNeeded = true
                } label: {
                    actionNeededBadge
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what needs attention for each tyre")
            }
        }
    }

    private var actionNeededBadge: some View {
        let label = actionNeededCount == 1 ? "1 action needed" : "\(actionNeededCount) actions needed"
        return HStack(spacing: 6) {
            Circle()
                .fill(AppColors.orange)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(AppColors.orange.opacity(0.14))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var setupBar: some View {
        HStack(spacing: AppScreenMetrics.smallSpacing) {
            Text(TyreSupport.layoutSummary(for: profile, records: records))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSupporting)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit setup", action: onShowSetup)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Edit tyre setup")
        }
        .padding(.horizontal, AppScreenMetrics.cardInteriorPadding)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                .fill(LyneqoTheme.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                .strokeBorder(LyneqoTheme.border.opacity(0.35), lineWidth: 1)
        }
    }

    private var quickActionsRow: some View {
        HStack(spacing: AppScreenMetrics.controlSpacing) {
            Button(action: onShowHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("View tyre history")

            Button(action: onShowInfo) {
                Image(systemName: "info.circle")
                    .font(.body.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Tyre Safety information")
            .pointerHelp("Tyre Safety information")
        }
    }

    private var recommendedRecordBox: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            Text("Recommended record")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("Manufacture date code, target and measured pressure, tread depth, visible damage, position, photo, inspection date and replacement decision.")
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }
}

private struct TyreCardsGrid: View {
    let records: [TyreRecord]
    let pressureUnit: PressureUnit
    let onSelectRecord: (TyreRecord) -> Void
    let onLogPressure: (TyreRecord) -> Void

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppScreenMetrics.controlSpacing) {
            ForEach(records) { record in
                TyreStatusCard(
                    record: record,
                    pressureUnit: pressureUnit,
                    onSelect: { onSelectRecord(record) },
                    onLogPressure: { onLogPressure(record) }
                )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: TyreGridWidthKey.self, value: geometry.size.width)
                    .allowsHitTesting(false)
            }
        )
        .onPreferenceChange(TyreGridWidthKey.self) { availableWidth = $0 }
    }

    /// Phone: single column (full-width cards). Larger widths: 3, then 4.
    private var columns: [GridItem] {
        let maxColumns: Int
        if availableWidth >= 900 {
            maxColumns = 4
        } else if availableWidth >= 560 {
            maxColumns = 3
        } else {
            maxColumns = 1
        }
        let columnCount = min(max(records.count, 1), maxColumns)
        return Array(
            repeating: GridItem(.flexible(), spacing: AppScreenMetrics.controlSpacing),
            count: columnCount
        )
    }
}

private struct TyreGridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TyreStatusCard: View {
    let record: TyreRecord
    let pressureUnit: PressureUnit
    let onSelect: () -> Void
    let onLogPressure: () -> Void

    private let thumbnailSize: CGFloat = 84

    private var statusColor: Color {
        switch record.statusLevel {
        case .current: return AppColors.green
        case .attention: return AppColors.orange
        case .action: return AppColors.red
        case .incomplete: return AppColors.orange
        }
    }

    private var targetPressureText: String {
        guard let recommended = record.recommendedPressurePSI else { return "—" }
        return Formatters.pressure(recommended, unit: pressureUnit)
    }

    private var thumbnailImage: UIImage? {
        guard let photo = TyrePhotoStore.diagramPhoto(for: record) else { return nil }
        return TyrePhotoStore.loadImage(for: photo, vehicleID: record.vehicleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    HStack(alignment: .top, spacing: AppScreenMetrics.smallSpacing) {
                        Image(systemName: "circle.circle")
                            .font(.title3)
                            .foregroundStyle(statusColor)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                                .font(.headline)
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            Text(record.dateCodeCaption)
                                .font(.caption)
                                .foregroundStyle(AppColors.textSupporting)
                                .lineLimit(1)
                        }

                        Spacer(minLength: AppScreenMetrics.tinySpacing)

                        tyreThumbnail
                    }

                    HStack(alignment: .top, spacing: AppScreenMetrics.smallSpacing) {
                        metricColumn(title: "Target pressure", value: targetPressureText)
                        metricColumn(title: "Tyre age", value: record.compactAgeText)
                    }

                    VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
                        Text("Condition")
                            .font(.caption)
                            .foregroundStyle(AppColors.textSupporting)
                        Text(record.conditionCallToAction)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens tyre details")

            Button(action: record.statusLevel == .incomplete ? onSelect : onLogPressure) {
                Text(record.statusLevel == .incomplete ? "Add tyre information" : "Log pressure or photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                record.statusLevel == .incomplete
                    ? "Add information for \(record.displayName)"
                    : "Log pressure or photo for \(record.displayName)"
            )
            .accessibilityHint(
                record.statusLevel == .incomplete
                    ? "Opens tyre details"
                    : "Opens pressure and photo inspection for this tyre"
            )
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        // Do not use maxHeight: .infinity — it expands hit testing over later cards in the grid.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .fill(LyneqoTheme.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .strokeBorder(statusColor.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var tyreThumbnail: some View {
        Group {
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LyneqoTheme.softTeal
                    Image(systemName: "camera.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textSupporting)
                }
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusColor.opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let photoNote = thumbnailImage == nil ? "no photo" : "photo available"
        return "\(record.displayName), \(record.conditionCallToAction), age \(record.compactAgeText), \(photoNote)"
    }

    private func metricColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TyreActionsNeededSheet: View {
    @Environment(\.dismiss) private var dismiss

    let records: [TyreRecord]
    let onSelectRecord: (TyreRecord) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "exclamationmark.circle",
                        title: records.count == 1 ? "1 action needed" : "\(records.count) actions needed",
                        subtitle: "Tap a tyre to open its details and complete the outstanding items."
                    )

                    AppSettingsSection("Outstanding items") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                            ForEach(records) { record in
                                Button {
                                    onSelectRecord(record)
                                } label: {
                                    actionRow(for: record)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Actions needed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func actionRow(for record: TyreRecord) -> some View {
        let messages = actionMessages(for: record)
        return VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: AppScreenMetrics.smallSpacing) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: AppScreenMetrics.tinySpacing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
            }
            Text(record.conditionCallToAction)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.orange)
            ForEach(messages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                .fill(AppColors.orange.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens tyre details")
    }

    private func actionMessages(for record: TyreRecord) -> [String] {
        var messages: [String] = []
        switch record.statusLevel {
        case .incomplete:
            if record.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append("Add the tyre manufacturer.")
            }
            if record.manufactureDate == nil {
                messages.append("Record the manufacture date code from the sidewall.")
            }
            if record.recommendedPressurePSI == nil {
                messages.append("Record the recommended cold pressure.")
            }
            if record.condition == .notChecked {
                messages.append("Record the overall tyre condition.")
            }
        case .attention, .action:
            messages.append(contentsOf: record.alertMessages)
        case .current:
            break
        }
        if messages.isEmpty {
            messages.append(record.conditionCallToAction)
        }
        return messages
    }
}

private struct TyreSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let profile: VehicleProfile
    let existingRecords: [TyreRecord]

    @State private var selectedLayout: TyreLayout
    @State private var includeSpare: Bool

    init(profile: VehicleProfile, existingRecords: [TyreRecord]) {
        self.profile = profile
        self.existingRecords = existingRecords
        let suggested = TyreStore.suggestedLayout(for: existingRecords, kind: profile.kind)
            ?? TyreSupport.layoutOptions(for: profile.kind).first
            ?? .caravanSingleAxle
        _selectedLayout = State(initialValue: suggested)
        _includeSpare = State(initialValue: existingRecords.contains(where: \.isSpare))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "circle.hexagongrid.fill",
                        title: "Set up your tyres",
                        subtitle: "Select the tyre arrangement fitted to this vehicle."
                    )

                    AppSettingsSection("Layout") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                            ForEach(TyreSupport.layoutOptions(for: profile.kind)) { layout in
                                Button {
                                    selectedLayout = layout
                                } label: {
                                    HStack {
                                        Text(layout.displayName)
                                            .foregroundStyle(Color.primary)
                                        Spacer()
                                        Image(systemName: selectedLayout == layout ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedLayout == layout ? Color.accentColor : Color.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                            Toggle(profile.kind == .caravan ? "Add spare tyre" : "Add spare tyre", isOn: $includeSpare)
                        }
                    }

                    if !existingRecords.isEmpty {
                        AppWarningBanner(message: "Changing the layout will keep your tyre history. Existing fitted tyres that no longer match the new layout will be archived rather than deleted.")
                    }

                    VStack(spacing: AppScreenMetrics.controlSpacing) {
                        AppPrimaryButton("Save layout") {
                            TyreStore.createLayout(for: profile, layout: selectedLayout, includeSpare: includeSpare, in: modelContext)
                            dismiss()
                        }
                        AppSecondaryButton("Skip for now") { dismiss() }
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Tyre layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct TyreDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TyreSupport.pressureUnitAppStorageKey) private var pressureUnitRaw = PressureUnit.psi.rawValue

    let record: TyreRecord
    let siblingRecords: [TyreRecord]
    private let originalSnapshot: TyreDetailEditorSnapshot

    @State private var manufacturer: String
    @State private var modelName: String
    @State private var tyreSize: String
    @State private var loadIndex: String
    @State private var speedRating: String
    @State private var dateCode: String
    @State private var recommendedPressure: String
    @State private var latestPressure: String
    @State private var latestPressureDate: Date
    @State private var notes: String
    @State private var installedDate: Date
    @State private var removedDate: Date
    @State private var isCurrentlyFitted: Bool
    @State private var dateCodeError: String?
    @State private var previewManufactureDate: Date?
    @State private var showHistory = false
    @State private var showReplaceConfirm = false
    @State private var showCopyFrom = false
    @State private var isAnalyzingSidewall = false
    @State private var sidewallSuggestions: TyreSidewallSuggestions?
    @State private var sidewallAnalysisError: String?
    @State private var persistTask: Task<Void, Never>?

    init(record: TyreRecord, siblingRecords: [TyreRecord]) {
        self.record = record
        self.siblingRecords = siblingRecords
        let unit = PressureUnit(rawValue: UserDefaults.standard.string(forKey: TyreSupport.pressureUnitAppStorageKey) ?? PressureUnit.psi.rawValue) ?? .psi
        _manufacturer = State(initialValue: record.manufacturer)
        _modelName = State(initialValue: record.modelName)
        _tyreSize = State(initialValue: record.tyreSize)
        _loadIndex = State(initialValue: record.loadIndex)
        _speedRating = State(initialValue: record.speedRating)
        _dateCode = State(initialValue: record.dateCode)
        _recommendedPressure = State(initialValue: record.recommendedPressurePSI.map { Self.displayPressure($0, unit: unit) } ?? "")
        _latestPressure = State(initialValue: record.latestPressurePSI.map { Self.displayPressure($0, unit: unit) } ?? "")
        _latestPressureDate = State(initialValue: record.latestPressureDate ?? Date())
        _notes = State(initialValue: record.notes)
        _installedDate = State(initialValue: record.installedDate ?? Date())
        _removedDate = State(initialValue: record.removedDate ?? Date())
        _isCurrentlyFitted = State(initialValue: record.isCurrentlyFitted)
        _previewManufactureDate = State(initialValue: record.manufactureDate)
        originalSnapshot = TyreDetailEditorSnapshot(
            manufacturer: record.manufacturer,
            modelName: record.modelName,
            tyreSize: record.tyreSize,
            loadIndex: record.loadIndex,
            speedRating: record.speedRating,
            dateCode: record.dateCode,
            recommendedPressure: record.recommendedPressurePSI.map { Self.displayPressure($0, unit: unit) } ?? "",
            latestPressure: record.latestPressurePSI.map { Self.displayPressure($0, unit: unit) } ?? "",
            latestPressureDate: record.latestPressureDate ?? Date(),
            notes: record.notes,
            installedDate: record.installedDate ?? Date(),
            removedDate: record.removedDate ?? Date(),
            isCurrentlyFitted: record.isCurrentlyFitted
        )
    }

    private var canCopyFromSibling: Bool {
        siblingRecords.contains { TyreCopyableDetails.from($0).hasAnyValue }
    }

    private var manufactureDateAgeCaption: String {
        if let previewManufactureDate {
            return TyreSupport.ageText(for: previewManufactureDate)
        }
        return "Manufacture date not recorded"
    }

    private var pressureUnit: PressureUnit {
        PressureUnit(rawValue: pressureUnitRaw) ?? .psi
    }

    private var editorSnapshot: TyreDetailEditorSnapshot {
        TyreDetailEditorSnapshot(
            manufacturer: manufacturer,
            modelName: modelName,
            tyreSize: tyreSize,
            loadIndex: loadIndex,
            speedRating: speedRating,
            dateCode: dateCode,
            recommendedPressure: recommendedPressure,
            latestPressure: latestPressure,
            latestPressureDate: latestPressureDate,
            notes: notes,
            installedDate: installedDate,
            removedDate: removedDate,
            isCurrentlyFitted: isCurrentlyFitted
        )
    }

    private var hasUnsavedDetailEdits: Bool {
        editorSnapshot != originalSnapshot
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: record.statusLevel.symbolName,
                        title: record.displayName,
                        subtitle: "\(record.ageText)\n\(record.pressureAssessment.status)\nCondition: \(record.condition.displayName)"
                    )

                    TyrePhotoGallerySection(
                        vehicleID: record.vehicleID,
                        record: record,
                        onAnalyzeSidewall: { photo in
                            analyzeSidewallPhoto(photo)
                        }
                    )

                    if isAnalyzingSidewall {
                        ProgressView("Analysing sidewall photo...")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let sidewallAnalysisError {
                        AppWarningBanner(message: sidewallAnalysisError)
                    }

                    AppSettingsSection("Identification") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            AppLabeledTextField("Manufacturer", placeholder: "e.g. Michelin", text: $manufacturer)
                            AppLabeledTextField("Model", placeholder: "e.g. Agilis", text: $modelName)
                            AppLabeledTextField("Tyre size", placeholder: "e.g. 225/75 R16", text: $tyreSize)
                            AppLabeledTextField("Load index", placeholder: "e.g. 121", text: $loadIndex)
                            AppLabeledTextField("Speed rating", placeholder: "e.g. R", text: $speedRating)
                            AppLabeledTextField(
                                "Manufacture date code",
                                caption: "The final four digits of the tyre identification marking show the week and year of manufacture. For example, 1221 means the tyre was manufactured during week 12 of 2021.",
                                placeholder: "e.g. 1221",
                                text: $dateCode,
                                keyboard: .numberPad,
                                onEditingEnded: commitDateCode
                            )
                            if let dateCodeError {
                                Text(dateCodeError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Text(manufactureDateAgeCaption)
                                .font(.caption)
                                .foregroundStyle(AppColors.textSupporting)
                        }
                    }

                    AppSettingsSection("Pressure") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            AppLabeledTextField("Recommended cold pressure (\(pressureUnit.displayName))", placeholder: pressureUnit == .psi ? "65" : "4.5", text: $recommendedPressure, keyboard: .decimalPad)
                            AppLabeledTextField("Latest measured pressure (\(pressureUnit.displayName))", placeholder: pressureUnit == .psi ? "65" : "4.5", text: $latestPressure, keyboard: .decimalPad)
                            DatePicker("Date measured", selection: $latestPressureDate, displayedComponents: .date)
                        }
                    }

                    AppSettingsSection("Installation") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            DatePicker("Date fitted", selection: $installedDate, displayedComponents: .date)
                            Toggle("Currently fitted", isOn: $isCurrentlyFitted)
                            if !isCurrentlyFitted {
                                DatePicker("Date removed", selection: $removedDate, displayedComponents: .date)
                            }
                        }
                    }

                    AppSettingsSection("Notes") {
                        AppNotesEditor(text: $notes)
                    }

                    VStack(spacing: AppScreenMetrics.controlSpacing) {
                        AppPrimaryButton("Save tyre details", systemImage: "checkmark.circle.fill") {
                            saveAndDismiss()
                        }
                        if canCopyFromSibling {
                            AppSecondaryButton("Copy from another tyre") { showCopyFrom = true }
                        }
                        AppSecondaryButton("View history") { showHistory = true }
                        AppSecondaryButton("Replace tyre") { showReplaceConfirm = true }
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Tyre details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        flushPersist()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: editorSnapshot) { _, _ in
                schedulePersist()
            }
            .onDisappear {
                flushPersist()
            }
            .sheet(isPresented: $showHistory) {
                TyreRecordHistoryView(
                    record: record,
                    previousRecords: TyreStore.previousRecords(for: record, in: modelContext)
                )
            }
            .sheet(isPresented: $showCopyFrom) {
                TyreCopyFromSheet(sources: siblingRecords) { manufacturerValue, modelNameValue, tyreSizeValue, loadIndexValue, speedRatingValue, dateCodeValue, recommendedPressureValue in
                    applyCopiedDetails(
                        manufacturer: manufacturerValue,
                        modelName: modelNameValue,
                        tyreSize: tyreSizeValue,
                        loadIndex: loadIndexValue,
                        speedRating: speedRatingValue,
                        dateCode: dateCodeValue,
                        recommendedPressurePSI: recommendedPressureValue
                    )
                }
            }
            .sheet(item: Binding(
                get: {
                    sidewallSuggestions?.hasAnySuggestion == true ? sidewallSuggestions : nil
                },
                set: { newValue in
                    sidewallSuggestions = newValue
                }
            )) { suggestions in
                TyreSidewallReviewSheet(suggestions: suggestions) { manufacturerValue, modelNameValue, tyreSizeValue, loadIndexValue, speedRatingValue, dateCodeValue in
                    applySidewallSuggestions(
                        manufacturer: manufacturerValue,
                        modelName: modelNameValue,
                        tyreSize: tyreSizeValue,
                        loadIndex: loadIndexValue,
                        speedRating: speedRatingValue,
                        dateCode: dateCodeValue
                    )
                }
            }
            .alert("Replace tyre", isPresented: $showReplaceConfirm) {
                Button("Copy manufacturer and model") {
                    flushPersist()
                    _ = TyreStore.replaceTyre(record, copyManufacturerAndModel: true, in: modelContext)
                    dismiss()
                }
                Button("Do not copy manufacturer or model") {
                    flushPersist()
                    _ = TyreStore.replaceTyre(record, copyManufacturerAndModel: false, in: modelContext)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The existing tyre will be marked as no longer fitted. Its basic details stay in history, and a new tyre record will be created at the same position.")
            }
        }
    }

    private func saveAndDismiss() {
        persistTask?.cancel()
        persistTask = nil
        let result = persistDetails(requireValidDateCode: true)
        if result != .blockedByInvalidDateCode {
            dismiss()
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persistDetails(requireValidDateCode: false)
        }
    }

    private func flushPersist() {
        persistTask?.cancel()
        persistTask = nil
        persistDetails(requireValidDateCode: false)
    }

    @discardableResult
    private func persistDetails(requireValidDateCode: Bool) -> TyreDetailsApplyResult {
        if !requireValidDateCode, !hasUnsavedDetailEdits {
            return .saved
        }
        if requireValidDateCode {
            dateCodeError = nil
        }
        let result = TyreStore.applyEditorDetails(
            to: record,
            manufacturer: manufacturer,
            modelName: modelName,
            tyreSize: tyreSize,
            loadIndex: loadIndex,
            speedRating: speedRating,
            dateCode: dateCode,
            recommendedPressureDisplay: recommendedPressure,
            latestPressureDisplay: latestPressure,
            latestPressureDate: latestPressureDate,
            notes: notes,
            installedDate: installedDate,
            removedDate: removedDate,
            isCurrentlyFitted: isCurrentlyFitted,
            pressureUnit: pressureUnit,
            requireValidDateCode: requireValidDateCode,
            in: modelContext
        )
        if result == .blockedByInvalidDateCode {
            dateCodeError = "Enter a valid four-digit week and year code that is not in the future."
        }
        return result
    }

    private func analyzeSidewallPhoto(_ photo: TyrePhoto) {
        isAnalyzingSidewall = true
        sidewallAnalysisError = nil
        Task {
            do {
                let suggestions = try await TyreSidewallOCR.analyze(photo: photo, vehicleID: record.vehicleID)
                await MainActor.run {
                    isAnalyzingSidewall = false
                    if suggestions.hasAnySuggestion {
                        sidewallSuggestions = suggestions
                    } else {
                        sidewallAnalysisError = suggestions.confidenceNotes.first ?? "No reliable sidewall text was recognised. Try a clearer photo."
                    }
                }
            } catch {
                await MainActor.run {
                    isAnalyzingSidewall = false
                    sidewallAnalysisError = "Could not analyse the sidewall photo on this device. Try a clearer photo and check the values manually."
                }
            }
        }
    }

    private func applySidewallSuggestions(
        manufacturer manufacturerValue: String?,
        modelName modelNameValue: String?,
        tyreSize tyreSizeValue: String?,
        loadIndex loadIndexValue: String?,
        speedRating speedRatingValue: String?,
        dateCode dateCodeValue: String?
    ) {
        if let manufacturerValue, !manufacturerValue.isEmpty {
            manufacturer = manufacturerValue
        }
        if let modelNameValue, !modelNameValue.isEmpty {
            modelName = modelNameValue
        }
        if let tyreSizeValue, !tyreSizeValue.isEmpty {
            tyreSize = tyreSizeValue
        }
        if let loadIndexValue, !loadIndexValue.isEmpty {
            loadIndex = loadIndexValue
        }
        if let speedRatingValue, !speedRatingValue.isEmpty {
            speedRating = speedRatingValue
        }
        if let dateCodeValue, !dateCodeValue.isEmpty {
            dateCode = dateCodeValue
            commitDateCode()
        }
    }

    private func applyCopiedDetails(
        manufacturer manufacturerValue: String?,
        modelName modelNameValue: String?,
        tyreSize tyreSizeValue: String?,
        loadIndex loadIndexValue: String?,
        speedRating speedRatingValue: String?,
        dateCode dateCodeValue: String?,
        recommendedPressurePSI recommendedPressureValue: Double?
    ) {
        if let manufacturerValue, !manufacturerValue.isEmpty {
            manufacturer = manufacturerValue
            record.manufacturer = manufacturerValue
        }
        if let modelNameValue, !modelNameValue.isEmpty {
            modelName = modelNameValue
            record.modelName = modelNameValue
        }
        if let tyreSizeValue, !tyreSizeValue.isEmpty {
            tyreSize = tyreSizeValue
            record.tyreSize = tyreSizeValue
        }
        if let loadIndexValue, !loadIndexValue.isEmpty {
            loadIndex = loadIndexValue
            record.loadIndex = loadIndexValue
        }
        if let speedRatingValue, !speedRatingValue.isEmpty {
            speedRating = speedRatingValue
            record.speedRating = speedRatingValue
        }
        if let dateCodeValue, !dateCodeValue.isEmpty {
            dateCode = dateCodeValue
            commitDateCode()
            if let parsed = TyreSupport.parseDateCode(dateCodeValue) {
                record.dateCode = parsed.normalized
                record.manufactureWeek = parsed.week
                record.manufactureYear = parsed.year
                record.manufactureDate = parsed.manufactureDate
            }
        }
        if let recommendedPressureValue {
            recommendedPressure = Self.displayPressure(recommendedPressureValue, unit: pressureUnit)
            record.recommendedPressurePSI = recommendedPressureValue
        }
        record.updatedAt = Date()
        try? modelContext.save()
    }

    private func commitDateCode() {
        dateCodeError = nil
        let trimmedDateCode = dateCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDateCode.isEmpty else {
            previewManufactureDate = nil
            return
        }

        guard let parsed = TyreSupport.parseDateCode(trimmedDateCode) else {
            previewManufactureDate = nil
            dateCodeError = "Enter a valid four-digit week and year code that is not in the future."
            return
        }

        dateCode = parsed.normalized
        previewManufactureDate = parsed.manufactureDate
    }

    private static func displayPressure(_ pressurePSI: Double, unit: PressureUnit) -> String {
        let converted = TyreSupport.convertPressure(pressurePSI, from: .psi, to: unit)
        return String(format: unit == .psi ? "%.0f" : "%.1f", converted)
    }
}

private struct TyreDetailEditorSnapshot: Equatable {
    var manufacturer: String
    var modelName: String
    var tyreSize: String
    var loadIndex: String
    var speedRating: String
    var dateCode: String
    var recommendedPressure: String
    var latestPressure: String
    var latestPressureDate: Date
    var notes: String
    var installedDate: Date
    var removedDate: Date
    var isCurrentlyFitted: Bool
}

private struct TyreInspectionEditorSnapshot: Equatable {
    var inspectionDate: Date
    var pressure: String
    var treadDepth: String
    var hasCuts: Bool
    var hasBulges: Bool
    var hasCracking: Bool
    var hasUnevenWear: Bool
    var hasEmbeddedObjects: Bool
    var valveAppearsSound: Bool
    var wheelNutsChecked: Bool
    var overallCondition: TyreCondition
    var notes: String
    var pendingPhotoCount: Int
    var pendingPhotoKinds: [TyrePhotoKind]
}

struct TyreInspectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TyreSupport.pressureUnitAppStorageKey) private var pressureUnitRaw = PressureUnit.psi.rawValue

    let record: TyreRecord
    let profile: VehicleProfile

    @State private var inspectionDate = Date()
    @State private var pressure = ""
    @State private var treadDepth = ""
    @State private var hasCuts = false
    @State private var hasBulges = false
    @State private var hasCracking = false
    @State private var hasUnevenWear = false
    @State private var hasEmbeddedObjects = false
    @State private var valveAppearsSound = true
    @State private var wheelNutsChecked = true
    @State private var overallCondition: TyreCondition = .good
    @State private var notes = ""
    @State private var pendingPhotos: [(UIImage, TyrePhotoKind)] = []
    @State private var didAutoEscalateCondition = false
    @State private var persistTask: Task<Void, Never>?
    @State private var didCommitInspection = false

    init(record: TyreRecord, profile: VehicleProfile) {
        self.record = record
        self.profile = profile
        guard let draft = TyreInspectionDraftStore.load(for: record.id) else { return }
        _inspectionDate = State(initialValue: draft.inspectionDate)
        _pressure = State(initialValue: draft.pressure)
        _treadDepth = State(initialValue: draft.treadDepth)
        _hasCuts = State(initialValue: draft.hasCuts)
        _hasBulges = State(initialValue: draft.hasBulges)
        _hasCracking = State(initialValue: draft.hasCracking)
        _hasUnevenWear = State(initialValue: draft.hasUnevenWear)
        _hasEmbeddedObjects = State(initialValue: draft.hasEmbeddedObjects)
        _valveAppearsSound = State(initialValue: draft.valveAppearsSound)
        _wheelNutsChecked = State(initialValue: draft.wheelNutsChecked)
        _overallCondition = State(initialValue: draft.overallCondition)
        _notes = State(initialValue: draft.notes)
        _pendingPhotos = State(initialValue: TyreInspectionDraftStore.loadPhotos(for: record.id, from: draft))
    }

    private var pressureUnit: PressureUnit {
        PressureUnit(rawValue: pressureUnitRaw) ?? .psi
    }

    private var hasSeriousDefectDraft: Bool {
        TyreSupport.draftHasSeriousDefect(
            hasCuts: hasCuts,
            hasBulges: hasBulges,
            hasCracking: hasCracking,
            hasUnevenWear: hasUnevenWear,
            hasEmbeddedObjects: hasEmbeddedObjects
        )
    }

    private var requiresReview: Bool {
        TyreSupport.draftRequiresProfessionalReview(
            hasCuts: hasCuts,
            hasBulges: hasBulges,
            hasCracking: hasCracking,
            hasUnevenWear: hasUnevenWear,
            hasEmbeddedObjects: hasEmbeddedObjects,
            valveAppearsSound: valveAppearsSound,
            wheelNutsChecked: wheelNutsChecked,
            overallCondition: overallCondition
        )
    }

    private var inspectionSnapshot: TyreInspectionEditorSnapshot {
        TyreInspectionEditorSnapshot(
            inspectionDate: inspectionDate,
            pressure: pressure,
            treadDepth: treadDepth,
            hasCuts: hasCuts,
            hasBulges: hasBulges,
            hasCracking: hasCracking,
            hasUnevenWear: hasUnevenWear,
            hasEmbeddedObjects: hasEmbeddedObjects,
            valveAppearsSound: valveAppearsSound,
            wheelNutsChecked: wheelNutsChecked,
            overallCondition: overallCondition,
            notes: notes,
            pendingPhotoCount: pendingPhotos.count,
            pendingPhotoKinds: pendingPhotos.map(\.1)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "checklist",
                        title: "Tyre inspection",
                        subtitle: record.displayName
                    )

                    AppSettingsSection("Inspection") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            DatePicker("Inspection date", selection: $inspectionDate, displayedComponents: .date)
                            AppLabeledTextField("Pressure (\(pressureUnit.displayName))", placeholder: pressureUnit == .psi ? "65" : "4.5", text: $pressure, keyboard: .decimalPad)
                            AppLabeledTextField("Tread depth (mm)", placeholder: "e.g. 5.8", text: $treadDepth, keyboard: .decimalPad)
                        }
                    }

                    AppSettingsSection("Visible checks") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            defectToggle("Visible cuts", value: $hasCuts)
                            defectToggle("Bulges", value: $hasBulges)
                            defectToggle("Cracking or perishing", value: $hasCracking)
                            defectToggle("Uneven wear", value: $hasUnevenWear)
                            defectToggle("Embedded objects", value: $hasEmbeddedObjects)
                            defectToggle("Valve appears sound", value: $valveAppearsSound)
                            defectToggle(
                                "Wheel nuts checked",
                                caption: profile.hasActiveWheelNutTorque
                                    ? "Target \(Formatters.nm(profile.activeWheelNutTorqueNm))"
                                    : nil,
                                value: $wheelNutsChecked
                            )
                            Picker("Overall condition", selection: $overallCondition) {
                                ForEach(TyreCondition.allCases.filter { $0 != .notChecked }) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            AppNotesEditor(text: $notes)
                        }
                    }

                    TyrePendingPhotoSection(pendingImages: $pendingPhotos)

                    if requiresReview {
                        AppWarningBanner(message: "Professional inspection recommended before travelling.")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    AppPrimaryButton("Save inspection", systemImage: "checkmark.circle.fill") {
                        persistTask?.cancel()
                        persistTask = nil
                        didCommitInspection = true
                        let inspection = TyreStore.addInspection(
                            to: record,
                            inspectionDate: inspectionDate,
                            pressurePSI: parsePressure(pressure),
                            treadDepthMM: Double(treadDepth),
                            hasCuts: hasCuts,
                            hasBulges: hasBulges,
                            hasCracking: hasCracking,
                            hasUnevenWear: hasUnevenWear,
                            hasEmbeddedObjects: hasEmbeddedObjects,
                            valveAppearsSound: valveAppearsSound,
                            wheelNutsChecked: wheelNutsChecked,
                            overallCondition: overallCondition,
                            notes: notes,
                            in: modelContext
                        )
                        TyrePhotoStore.savePending(
                            images: pendingPhotos,
                            vehicleID: record.vehicleID,
                            record: record,
                            inspection: inspection,
                            in: modelContext
                        )
                        TyreInspectionDraftStore.clear(for: record.id)
                        dismiss()
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
                .animation(.easeInOut(duration: 0.2), value: requiresReview)
            }
            .appScreenBackground()
            .navigationTitle("Inspection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        flushInspectionDraft()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: inspectionSnapshot) { _, _ in
                scheduleInspectionDraftPersist()
            }
            .onDisappear {
                flushInspectionDraft()
            }
            .onChange(of: hasSeriousDefectDraft) { _, hasDefect in
                syncConditionWithDefects(hasDefect: hasDefect)
            }
            .onChange(of: valveAppearsSound) { _, isSound in
                syncConditionWithChecks(checkFailed: !isSound || !wheelNutsChecked)
            }
            .onChange(of: wheelNutsChecked) { _, isChecked in
                syncConditionWithChecks(checkFailed: !valveAppearsSound || !isChecked)
            }
            .onChange(of: overallCondition) { _, newValue in
                if newValue != .monitor {
                    didAutoEscalateCondition = false
                }
            }
        }
    }

    private func syncConditionWithDefects(hasDefect: Bool) {
        if hasDefect {
            escalateConditionIfNeeded()
        } else if !hasFailedSoundnessChecks {
            clearAutoEscalatedConditionIfNeeded()
        }
    }

    private func syncConditionWithChecks(checkFailed: Bool) {
        if checkFailed {
            escalateConditionIfNeeded()
        } else if !hasSeriousDefectDraft {
            clearAutoEscalatedConditionIfNeeded()
        }
    }

    private var hasFailedSoundnessChecks: Bool {
        !valveAppearsSound || !wheelNutsChecked
    }

    private func escalateConditionIfNeeded() {
        guard overallCondition == .good else { return }
        overallCondition = .monitor
        didAutoEscalateCondition = true
    }

    private func clearAutoEscalatedConditionIfNeeded() {
        guard didAutoEscalateCondition, overallCondition == .monitor else { return }
        overallCondition = .good
        didAutoEscalateCondition = false
    }

    @ViewBuilder
    private func defectToggle(_ title: String, caption: String? = nil, value: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker(title, selection: value) {
                Text("No").tag(false)
                Text("Yes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func parsePressure(_ input: String) -> Double? {
        guard let displayValue = Double(input) else { return nil }
        return TyreSupport.convertPressure(displayValue, from: pressureUnit, to: .psi)
    }

    private func scheduleInspectionDraftPersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persistInspectionDraft()
        }
    }

    private func flushInspectionDraft() {
        persistTask?.cancel()
        persistTask = nil
        persistInspectionDraft()
    }

    private func persistInspectionDraft() {
        guard !didCommitInspection else { return }
        TyreInspectionDraftStore.save(
            TyreInspectionDraft(
                inspectionDate: inspectionDate,
                pressure: pressure,
                treadDepth: treadDepth,
                hasCuts: hasCuts,
                hasBulges: hasBulges,
                hasCracking: hasCracking,
                hasUnevenWear: hasUnevenWear,
                hasEmbeddedObjects: hasEmbeddedObjects,
                valveAppearsSound: valveAppearsSound,
                wheelNutsChecked: wheelNutsChecked,
                overallConditionRaw: overallCondition.rawValue,
                notes: notes,
                photos: []
            ),
            images: pendingPhotos,
            for: record.id
        )
    }
}

private struct TyreHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let activeRecords: [TyreRecord]
    let archivedRecords: [TyreRecord]

    var body: some View {
        NavigationStack {
            List {
                if !archivedRecords.isEmpty {
                    Section {
                        ForEach(archivedRecords) { record in
                            previousTyreRow(record)
                        }
                    } header: {
                        Text("Previous tyres")
                    } footer: {
                        Text("Basic details kept when a tyre is replaced or removed from the layout.")
                    }
                }

                ForEach(activeRecords) { record in
                    Section(record.displayName) {
                        if record.inspectionsList.isEmpty {
                            Text("No inspection history recorded yet.")
                                .foregroundStyle(AppColors.textSupporting)
                        } else {
                            ForEach(record.inspectionsList) { inspection in
                                inspectionRow(inspection, vehicleID: record.vehicleID)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tyre history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func previousTyreRow(_ record: TyreRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.displayName)
                .font(.subheadline.weight(.semibold))
            Text(record.historyIdentitySummary)
                .font(.caption)
            Text(record.dateCodeCaption)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
            Text(record.historyServicePeriod)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
            if record.condition != .notChecked {
                Text("Condition when removed: \(record.condition.displayName)")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
        }
        .padding(.vertical, 4)
    }

    private func inspectionRow(_ inspection: TyreInspection, vehicleID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Formatters.date(inspection.inspectionDate))
                .font(.subheadline.weight(.semibold))
            Text("Condition: \(inspection.overallCondition.displayName)")
                .font(.caption)
            if let pressure = inspection.pressurePSI {
                Text("Pressure: \(Formatters.pressure(pressure, unit: .psi))")
                    .font(.caption)
            }
            if let tread = inspection.treadDepthMM {
                Text("Tread depth: \(String(format: "%.1f", tread)) mm")
                    .font(.caption)
            }
            if !inspection.notes.isEmpty {
                Text(inspection.notes)
                    .font(.caption)
            }
            TyreInspectionPhotoStrip(
                photos: inspection.photosList,
                vehicleID: vehicleID
            )
        }
        .padding(.vertical, 4)
    }
}

private struct TyreRecordHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let record: TyreRecord
    let previousRecords: [TyreRecord]

    private var hasContent: Bool {
        !previousRecords.isEmpty
            || !record.generalPhotosList().isEmpty
            || !record.inspectionsList.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !previousRecords.isEmpty {
                    Section {
                        ForEach(previousRecords) { previous in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(previous.historyIdentitySummary)
                                    .font(.subheadline.weight(.semibold))
                                Text(previous.dateCodeCaption)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                Text(previous.historyServicePeriod)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                if previous.condition != .notChecked {
                                    Text("Condition when removed: \(previous.condition.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSupporting)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Previous tyres at this position")
                    } footer: {
                        Text("Kept when you use Replace tyre. Specs and dates only — not pressure logs.")
                    }
                }

                if !record.generalPhotosList().isEmpty {
                    Section("Tyre photos") {
                        TyreInspectionPhotoStrip(
                            photos: record.generalPhotosList(),
                            vehicleID: record.vehicleID
                        )
                    }
                }

                if !record.inspectionsList.isEmpty {
                    Section("Inspections") {
                        ForEach(record.inspectionsList) { inspection in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Formatters.date(inspection.inspectionDate))
                                    .font(.subheadline.weight(.semibold))
                                Text("Condition: \(inspection.overallCondition.displayName)")
                                    .font(.caption)
                                if let pressure = inspection.pressurePSI {
                                    Text("Pressure: \(Formatters.pressure(pressure, unit: .psi))")
                                        .font(.caption)
                                }
                                if let tread = inspection.treadDepthMM {
                                    Text("Tread depth: \(String(format: "%.1f", tread)) mm")
                                        .font(.caption)
                                }
                                if !inspection.notes.isEmpty {
                                    Text(inspection.notes)
                                        .font(.caption)
                                }
                                TyreInspectionPhotoStrip(
                                    photos: inspection.photosList,
                                    vehicleID: record.vehicleID
                                )
                            }
                        }
                    }
                }

                if !hasContent {
                    Section {
                        Text("No previous tyres or inspection history recorded yet.")
                            .foregroundStyle(AppColors.textSupporting)
                    }
                }
            }
            .navigationTitle("\(record.displayName) history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct TyreSafetyInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "info.circle",
                        title: "Tyre Safety information",
                        subtitle: "Advisory guidance only"
                    )
                    Text(TyreSupport.tyreDisclaimer)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Caravan tyres often cover low mileages but can still deteriorate with age, sunlight, loading and long periods of standing. Industry guidance commonly recommends reviewing replacement at around five years and avoiding continued use beyond seven years.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Wheel nut torque is for the fitted wheels on this vehicle, not each tyre. Caravan plates often list steel and alloy — use the figure for the wheels you have now. Motorhome torque comes from the base vehicle handbook.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Tyre photos are stored on this device for your records. Lyneqo Caravan & Motorhome does not analyse photos or draw conclusions about tyre condition from images.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct WheelNutTorqueSection: View {
    @Environment(\.modelContext) private var modelContext
    let profile: VehicleProfile

    var body: some View {
        AppGroupedCard {
            HStack(alignment: .center, spacing: AppScreenMetrics.controlSpacing) {
                VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
                    Text("Wheel nut torque")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(profile.wheelNutTorqueSectionCaption)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AppScreenMetrics.smallSpacing)

                if profile.kind == .caravan {
                    Picker("Fitted wheels", selection: fittedMaterialBinding) {
                        ForEach(FittedWheelMaterial.allCases) { material in
                            Text(material.displayName).tag(material)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                AppBoundedNumberField(
                    value: torqueBinding,
                    fractionDigitsUpperBound: 0
                )
                .frame(width: 120)

                Text("Nm")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
            }
        }
        .onAppear {
            profile.migrateLegacyMotorhomeWheelNutTorqueIfNeeded()
        }
    }

    private var fittedMaterialBinding: Binding<FittedWheelMaterial> {
        Binding(
            get: { profile.fittedWheelMaterial },
            set: { newValue in
                profile.fittedWheelMaterial = newValue
                _ = SyncDebugSaveHelper.save(modelContext, source: "TyreSafety.saveFittedWheelMaterial")
            }
        )
    }

    private var torqueBinding: Binding<Double> {
        Binding(
            get: { profile.activeWheelNutTorqueNm },
            set: { newValue in
                profile.activeWheelNutTorqueNm = newValue
                _ = SyncDebugSaveHelper.save(modelContext, source: "TyreSafety.saveWheelNutTorque")
            }
        )
    }
}

private struct AppNotesEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: 120)
            .padding(8)
            .background(LyneqoTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                    .strokeBorder(LyneqoTheme.border, lineWidth: 1)
            }
    }
}
