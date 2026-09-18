import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WarrantyView: View {
    @Environment(\.usePadLayout) private var usePadLayout
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var warrantyPlans: [WarrantyPlan]
    @Query private var maintenanceRecords: [MaintenanceRecord]
    @Query private var documentRecords: [DocumentRecord]
    @Query private var faultRecords: [FaultRecord]

    @State private var showSetup = false
    @State private var showEditPlan = false
    @State private var showAddEvent = false
    @State private var showInfo = false
    @State private var showAddFault = false
    @State private var exportPDFData: Data?
    @State private var selectedEvent: WarrantyEvent?
    @State private var costItemParent: WarrantyEvent?
    @State private var selectedFault: FaultRecord?
    @State private var showRegenerateConfirm = false
    @State private var showsAllCostYears = false

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(
            profiles: profiles,
            appState: AppStateStore.canonical(from: appStates)
        )
    }

    private var insuranceSyncToken: String {
        guard let profile = activeProfile else { return "none" }
        let dateToken = profile.insuranceStartDate.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"
        return "\(profile.id.uuidString)-\(dateToken)"
    }

    private var activePlan: WarrantyPlan? {
        guard let profile = activeProfile else { return nil }
        return WarrantySupport.plan(for: profile.id, from: warrantyPlans)
    }

    private var planEvents: [WarrantyEvent] {
        activePlan?.eventsList ?? []
    }

    private var scopedDocuments: [DocumentRecord] {
        guard let profile = activeProfile else { return [] }
        return MaintenanceSupport.documentRecords(for: profile.id, from: documentRecords)
    }

    private var scopedFaults: [FaultRecord] {
        guard let profile = activeProfile else { return [] }
        return MaintenanceSupport.faultRecords(for: profile.id, from: faultRecords)
    }

    private var scopedMaintenance: [MaintenanceRecord] {
        guard let profile = activeProfile else { return [] }
        return MaintenanceSupport.maintenanceRecords(for: profile.id, from: maintenanceRecords)
    }

    private var warrantyItems: [FaultRecord] {
        WarrantySupport.warrantyFaults(from: scopedFaults, events: planEvents)
    }

    private var otherFaults: [FaultRecord] {
        WarrantySupport.unflaggedFaults(from: scopedFaults, events: planEvents)
    }

    private var nextActionableEvent: WarrantyEvent? {
        guard let profile = activeProfile else { return nil }
        return WarrantySupport.nextActionableEvent(plans: warrantyPlans, vehicleID: profile.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = activeProfile {
                    if !profile.warrantyAvailable {
                        warrantyDisabledBody(profile: profile)
                    } else if let plan = activePlan {
                        configuredBody(profile: profile, plan: plan)
                    } else {
                        setupPromptBody(profile: profile)
                    }
                } else {
                    ContentUnavailableView(
                        "No vehicle selected",
                        systemImage: "shield",
                        description: Text("Add or select a caravan or motorhome in Settings to track warranty coverage.")
                    )
                }
            }
            .appScreenBackground()
            .appPrincipalTabTitle("Service & warranty")
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showSetup) {
            if let profile = activeProfile {
                WarrantyPlanEditorSheet(profile: profile, plan: nil) {
                    if let plan = activePlan {
                        WarrantyStore.generateAnnualEvents(
                            plan: plan,
                            in: modelContext,
                            kind: profile.kind,
                            ukMarket: profile.warrantyUKMarket
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showEditPlan) {
            if let profile = activeProfile, let plan = activePlan {
                WarrantyPlanEditorSheet(profile: profile, plan: plan) {
                    showRegenerateConfirm = true
                }
            }
        }
        .sheet(isPresented: $showAddEvent) {
            if let plan = activePlan {
                WarrantyEventEditorSheet(plan: plan, event: nil)
            }
        }
        .sheet(item: $selectedEvent) { event in
            if let plan = activePlan {
                WarrantyEventEditorSheet(plan: plan, event: event)
            }
        }
        .sheet(item: $costItemParent) { parentEvent in
            if let plan = activePlan {
                WarrantyEventEditorSheet(
                    plan: plan,
                    event: nil,
                    costItemFor: parentEvent
                )
            }
        }
        .sheet(isPresented: $showInfo) {
            WarrantyInfoSheet()
        }
        .sheet(isPresented: $showAddFault) {
            if let profile = activeProfile {
                FaultRecordEditorView(
                    profile: profile,
                    maintenanceRecords: scopedMaintenance,
                    defaultWarrantyRelated: true
                )
            }
        }
        .sheet(item: $selectedFault) { record in
            if let profile = activeProfile {
                FaultRecordEditorView(
                    profile: profile,
                    record: record,
                    maintenanceRecords: scopedMaintenance,
                    defaultWarrantyRelated: true,
                    suggestAsWarrantyItem: otherFaults.contains(where: { $0.id == record.id })
                )
            }
        }
        .sheet(item: Binding(
            get: { exportPDFData.map { WarrantyPDFShareItem(data: $0) } },
            set: { exportPDFData = $0?.data }
        )) { item in
            WarrantyEvidenceShareSheet(pdfData: item.data)
        }
        .task(id: insuranceSyncToken) {
            if let profile = activeProfile {
                WarrantyStore.syncInsuranceRenewalEvents(for: profile, in: modelContext)
            }
        }
        .onAppear {
            WarrantyStore.promoteEventAttachmentsToDocuments(events: planEvents, in: modelContext)
        }
        .confirmationDialog(
            "Regenerate auto events?",
            isPresented: $showRegenerateConfirm,
            titleVisibility: .visible
        ) {
            Button("Regenerate annual events") {
                if let plan = activePlan, let profile = activeProfile {
                    WarrantyStore.generateAnnualEvents(
                        plan: plan,
                        in: modelContext,
                        kind: profile.kind,
                        ukMarket: profile.warrantyUKMarket,
                        replaceAutoGenerated: true
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces auto-generated events with a fresh Year 1–\(activePlan?.durationYears ?? 8) schedule. Manual events are kept.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if activePlan != nil, activeProfile?.warrantyAvailable == true {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add service event", systemImage: "plus") { showAddEvent = true }
                    Button("Add warranty item", systemImage: "exclamationmark.triangle") { showAddFault = true }
                    Button("Edit plan", systemImage: "pencil") { showEditPlan = true }
                    Button("Export evidence pack", systemImage: "square.and.arrow.up") { exportEvidencePack() }
                    Button("About service & warranty", systemImage: "info.circle") { showInfo = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Service and warranty actions")
            }
        } else if activeProfile?.warrantyAvailable == true {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Set up", systemImage: "plus") { showSetup = true }
            }
        }
    }

    @ViewBuilder
    private func warrantyDisabledBody(profile: VehicleProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                ContentUnavailableView(
                    "Warranty tracking is off",
                    systemImage: "shield.slash",
                    description: Text("This vehicle is marked as having no warranty to track. Turn on Warranty available in Settings to show the warranty tab again.")
                )
            }
            .padding(.horizontal, AppScreenMetrics.horizontalPadding)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            .padReadableContent(maxWidth: usePadLayout ? 960 : PadContentLayout.readableMaxWidth)
        }
    }

    @ViewBuilder
    private func setupPromptBody(profile: VehicleProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                WarrantyDisclaimerInfoButton { showInfo = true }
                VehicleLookupSummarySection(profile: profile)

                AppSettingsSection("Get started", caption: "Build one continuous service timeline for this vehicle — warranty cover is optional.") {
                    VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                        Text("Log annual services and inspections whether a manufacturer is paying or you are. If cover is later refused or expires, the same timeline continues.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSupporting)
                        AppPrimaryButton("Set up service timeline", systemImage: "calendar.badge.plus") {
                            showSetup = true
                        }
                    }
                }
            }
            .padding(.horizontal, AppScreenMetrics.horizontalPadding)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            .padReadableContent(maxWidth: usePadLayout ? 960 : PadContentLayout.readableMaxWidth)
        }
    }

    @ViewBuilder
    private func configuredBody(profile: VehicleProfile, plan: WarrantyPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    WarrantyCoverageBanner(plan: plan)
                    if let next = nextActionableEvent {
                        WarrantyNextUpCard(
                            event: next,
                            events: plan.timelineEvents,
                            onSelect: { selectedEvent = next }
                        )
                    }
                }
                VehicleLookupSummarySection(profile: profile)

                yearlyCostsSection(events: plan.eventsList)

                AppSettingsSection(
                    "Service timeline",
                    caption: "Tap any row to edit. Use the switch to mark insurance done."
                ) {
                    VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                        WarrantyTimelineView(
                            plan: plan,
                            events: plan.timelineEvents,
                            onSelectEvent: { selectedEvent = $0 },
                            onAddCostItem: { costItemParent = $0 }
                        )
                        AppSecondaryButton("Add service event") {
                            showAddEvent = true
                        }
                    }
                }

                warrantyItemsSection
            }
            .padding(.horizontal, AppScreenMetrics.horizontalPadding)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            .padReadableContent(maxWidth: usePadLayout ? 960 : PadContentLayout.readableMaxWidth)
        }
    }

    @ViewBuilder
    private func yearlyCostsSection(events: [WarrantyEvent]) -> some View {
        let years = WarrantySupport.annualCosts(
            events: events,
            maintenanceRecords: scopedMaintenance,
            faults: scopedFaults
        )
        if !years.isEmpty {
            AppSettingsSection(
                "Yearly costs",
                caption: "Calendar-year totals from recorded costs."
            ) {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    ForEach(visibleCostYears(from: years)) { year in
                        HStack(alignment: .firstTextBaseline, spacing: AppScreenMetrics.controlSpacing) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(year.year))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(year.detail)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                            }
                            Spacer(minLength: 8)
                            Text(Formatters.currency(year.total))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                        }
                    }

                    if years.count > 2 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsAllCostYears.toggle()
                            }
                        } label: {
                            Label(
                                showsAllCostYears ? "Show fewer years" : "See all \(years.count) years",
                                systemImage: showsAllCostYears ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.purple)
                    }
                }
            }
        }
    }

    /// Keeps the section short: current and next year by default, with the most recent years as a fallback.
    private func visibleCostYears(from years: [WarrantySupport.AnnualCostYear]) -> [WarrantySupport.AnnualCostYear] {
        guard !showsAllCostYears, years.count > 2 else { return years }
        let currentYear = Calendar.current.component(.year, from: Date())
        let upcoming = years.filter { $0.year >= currentYear }
        guard upcoming.count >= 2 else { return Array(years.suffix(2)) }
        return Array(upcoming.prefix(2))
    }

    private var warrantyItemsSection: some View {
        AppSettingsSection(
            "Warranty items",
            caption: "Issues you are treating as warranty claims. Open or completed — separate from the service timeline."
        ) {
            if warrantyItems.isEmpty && otherFaults.isEmpty {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    Text("No warranty items yet.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSupporting)
                    AppSecondaryButton("Add warranty item") {
                        showAddFault = true
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    ForEach(warrantyItems) { record in
                        Button { selectedFault = record } label: {
                            warrantyRow(
                                title: record.title.isEmpty ? "Untitled item" : record.title,
                                subtitle: warrantyItemSubtitle(for: record),
                                systemImage: record.status.isResolved
                                    ? "checkmark.seal.fill"
                                    : "exclamationmark.triangle.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if !otherFaults.isEmpty {
                        Text("Other faults (not warranty items)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textSupporting)
                            .padding(.top, warrantyItems.isEmpty ? 0 : 4)

                        ForEach(otherFaults) { record in
                            Button { selectedFault = record } label: {
                                warrantyRow(
                                    title: record.title.isEmpty ? "Untitled fault" : record.title,
                                    subtitle: "Turn on Warranty item · \(record.status.displayName)",
                                    systemImage: "exclamationmark.triangle"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    AppSecondaryButton("Add warranty item") {
                        showAddFault = true
                    }
                }
            }
        }
    }

    private func warrantyItemSubtitle(for record: FaultRecord) -> String {
        var parts = [record.status.displayName, record.severity.displayName]
        if record.status.isResolved, let resolved = record.resolvedDate {
            parts.append("Resolved \(Formatters.date(resolved))")
        } else {
            parts.append("Found \(Formatters.date(record.discoveredDate))")
        }
        return parts.joined(separator: " · ")
    }

    private func warrantyRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
            Image(systemName: systemImage)
                .foregroundStyle(AppColors.purple)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
        }
    }

    private func exportEvidencePack() {
        guard let plan = activePlan, activeProfile != nil else { return }
        exportPDFData = WarrantyEvidencePackBuilder.buildPDF(
            input: .init(
                plan: plan,
                events: plan.eventsList,
                documents: scopedDocuments,
                maintenanceRecords: scopedMaintenance,
                faults: scopedFaults
            )
        )
    }
}

// MARK: - Banner & timeline components

struct WarrantyDisclaimerInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppScreenMetrics.controlSpacing) {
                Image(systemName: "info.circle")
                    .font(.body.weight(.medium))
                Text("About service & warranty")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, AppScreenMetrics.cardInteriorPadding)
            .padding(.vertical, 12)
            .background(LyneqoTheme.softTeal)
            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About service and warranty")
        .accessibilityHint("Shows how the service timeline relates to warranty cover")
    }
}

struct WarrantyDisclaimerBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.secondary)
            Text(WarrantySupport.warrantyDisclaimer)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(LyneqoTheme.softTeal)
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
    }
}

private struct WarrantyCoverageBanner: View {
    let plan: WarrantyPlan

    private var coverage: (title: String, detail: String, tintIsPositive: Bool) {
        WarrantySupport.coverageStatusText(plan: plan)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
            Image(systemName: coverage.tintIsPositive ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(coverage.tintIsPositive ? AppColors.green : AppColors.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(coverage.title)
                    .font(.headline.weight(.bold))
                Text(coverage.detail)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
            Spacer()
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background((coverage.tintIsPositive ? AppColors.green : AppColors.orange).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
    }
}

private func warrantyStatusColor(_ status: WarrantyEventStatus) -> Color {
    switch status {
    case .completed: return AppColors.green
    case .inWindow: return .accentColor
    case .overdue: return AppColors.red
    case .upcoming: return Color.secondary
    case .planned: return Color.secondary.opacity(0.85)
    }
}

/// Later years stay unbadged so overdue, in-window and completed rows stand out.
private func warrantyShowsStatusBadge(_ status: WarrantyEventStatus) -> Bool {
    status != .planned
}

private func warrantyDoneBinding(for event: WarrantyEvent, in context: ModelContext) -> Binding<Bool> {
    Binding(
        get: { event.completedDate != nil },
        set: { done in
            event.completedDate = done ? (event.completedDate ?? Date()) : nil
            event.updatedAt = Date()
            try? context.save()
        }
    )
}

private struct WarrantyStatusBadge: View {
    let status: WarrantyEventStatus

    var body: some View {
        Text(WarrantySupport.statusDisplayName(for: status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(warrantyStatusColor(status).opacity(0.15))
            .foregroundStyle(warrantyStatusColor(status))
            .clipShape(Capsule())
    }
}

/// Pulls the one thing to act on out of a long plan so it is visible without scrolling.
private struct WarrantyNextUpCard: View {
    @Environment(\.modelContext) private var modelContext

    let event: WarrantyEvent
    let events: [WarrantyEvent]
    let onSelect: () -> Void

    private var status: WarrantyEventStatus {
        WarrantySupport.status(for: event, among: events)
    }

    private var isInsurance: Bool {
        event.serviceType == .insuranceRenewal
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppScreenMetrics.controlSpacing) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: AppScreenMetrics.controlSpacing) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.title3)
                        .foregroundStyle(warrantyStatusColor(status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next up")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColors.textSupporting)
                        Text(isInsurance ? "Insurance" : event.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                        Text(Formatters.date(event.scheduledDate))
                            .font(.caption)
                            .foregroundStyle(AppColors.textSupporting)
                    }
                    Spacer(minLength: 8)
                    WarrantyStatusBadge(status: status)
                }
            }
            .buttonStyle(.plain)

            if isInsurance {
                Toggle("Done", isOn: warrantyDoneBinding(for: event, in: modelContext))
                    .labelsHidden()
                    .tint(AppColors.green)
                    .accessibilityLabel("Insurance done")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(LyneqoTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous)
                .stroke(LyneqoTheme.border, lineWidth: 1)
        }
    }
}

private struct WarrantyTimelineView: View {
    let plan: WarrantyPlan
    let events: [WarrantyEvent]
    let onSelectEvent: (WarrantyEvent) -> Void
    let onAddCostItem: (WarrantyEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrantyTimelineAnchorRow(
                title: "Purchase",
                subtitle: Formatters.date(plan.purchaseDate),
                isLast: events.isEmpty
            )

            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                let isLast = index == events.count - 1
                if event.serviceType == .insuranceRenewal {
                    WarrantyTimelineInsuranceRow(event: event, isLast: isLast) {
                        onSelectEvent(event)
                    }
                } else {
                    WarrantyTimelineEventRow(
                        event: event,
                        events: events,
                        costItems: plan.costItems(for: event),
                        isLast: isLast,
                        onSelect: { onSelectEvent(event) },
                        onSelectCostItem: onSelectEvent,
                        onAddCostItem: { onAddCostItem(event) }
                    )
                }
            }
        }
    }
}

private struct WarrantyTimelineInsuranceRow: View {
    @Environment(\.modelContext) private var modelContext

    let event: WarrantyEvent
    let isLast: Bool
    let onSelect: () -> Void

    private var isDone: Binding<Bool> {
        warrantyDoneBinding(for: event, in: modelContext)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(event.completedDate != nil ? AppColors.green : Color.secondary.opacity(0.85))
                    .frame(width: 12, height: 12)
                    .frame(width: 16, height: 16)
                if !isLast {
                    Rectangle()
                        .fill(LyneqoTheme.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: onSelect) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Insurance")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(Formatters.date(event.scheduledDate))
                            .font(.caption)
                            .foregroundStyle(AppColors.textSupporting)
                        Spacer(minLength: 8)
                        Text(WarrantySupport.costCaption(for: event))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                WarrantySupport.hasRecordedCost(for: event)
                                    ? Color.primary
                                    : AppColors.purple
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Insurance renewal, \(Formatters.date(event.scheduledDate)), \(WarrantySupport.costCaption(for: event))")
                }
                .buttonStyle(.plain)

                Toggle("Done", isOn: isDone)
                    .labelsHidden()
                    .tint(AppColors.green)
                    .accessibilityLabel("Insurance done")
            }
            .padding(.bottom, isLast ? 0 : AppScreenMetrics.fieldSpacing)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WarrantyTimelineAnchorRow: View {
    let title: String
    let subtitle: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(AppColors.purple)
                    .frame(width: 12, height: 12)
                if !isLast {
                    Rectangle()
                        .fill(LyneqoTheme.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
            .padding(.bottom, isLast ? 0 : AppScreenMetrics.controlSpacing)
        }
    }
}

private struct WarrantyTimelineEventRow: View {
    let event: WarrantyEvent
    let events: [WarrantyEvent]
    let costItems: [WarrantyEvent]
    let isLast: Bool
    let onSelect: () -> Void
    let onSelectCostItem: (WarrantyEvent) -> Void
    let onAddCostItem: () -> Void

    private var status: WarrantyEventStatus {
        WarrantySupport.status(for: event, among: events)
    }

    @State private var showsDetail = false

    private var isImportantMilestone: Bool {
        event.isImportantMilestone
    }

    private var evidenceCount: Int {
        event.attachmentsList.count + event.linkedDocumentIDs.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                timelineMarker
                if !isLast {
                    Rectangle()
                        .fill(LyneqoTheme.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 8) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(event.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isImportantMilestone ? AppColors.purple : Color.primary)
                            Spacer(minLength: 8)
                            if evidenceCount > 0 {
                                Label("\(evidenceCount)", systemImage: "paperclip")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppColors.purple)
                            }
                            if warrantyShowsStatusBadge(status) {
                                WarrantyStatusBadge(status: status)
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Formatters.date(event.scheduledDate))
                                .font(.caption)
                                .foregroundStyle(AppColors.textSupporting)
                            Spacer(minLength: 8)
                            Text(WarrantySupport.costCaption(for: event))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    WarrantySupport.hasRecordedCost(for: event)
                                        ? Color.primary
                                        : AppColors.purple
                                )
                        }

                        if isImportantMilestone {
                            Text("Important year — complete on or before the purchase anniversary")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppColors.purple)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
                }
                .buttonStyle(.plain)

                detailDisclosure

                WarrantyCostItemsBlock(
                    event: event,
                    items: costItems,
                    onSelectItem: onSelectCostItem,
                    onAddItem: onAddCostItem
                )
            }
            .padding(.bottom, isLast ? 0 : AppScreenMetrics.sectionSpacing)
        }
    }

    /// Requirement and window text is long, so it stays folded until asked for.
    @ViewBuilder
    private var detailDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsDetail.toggle()
                }
            } label: {
                Label(
                    showsDetail ? "Hide details" : "What's involved",
                    systemImage: showsDetail ? "chevron.up" : "chevron.down"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.purple)
            .accessibilityHint("Shows the requirement and action window for this service")

            if showsDetail {
                Text(event.requirementText)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(WarrantySupport.windowSubtitle(for: event))
                    .font(.caption2)
                    .foregroundStyle(isImportantMilestone ? AppColors.purple.opacity(0.9) : AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var timelineMarker: some View {
        if isImportantMilestone {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.purple)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .frame(width: 16, height: 16)
        }
    }

    private var accessibilityLabel: String {
        var parts = [event.displayTitle, WarrantySupport.statusDisplayName(for: status)]
        if isImportantMilestone {
            parts.insert("Important year", at: 0)
        }
        parts.append(WarrantySupport.costCaption(for: event))
        return parts.joined(separator: ", ")
    }

    private var statusColor: Color {
        warrantyStatusColor(status)
    }
}

private struct WarrantyCostItemsBlock: View {
    let event: WarrantyEvent
    let items: [WarrantyEvent]
    let onSelectItem: (WarrantyEvent) -> Void
    let onAddItem: () -> Void

    private var scopeLabel: String {
        event.yearNumber > 0 ? "year \(event.yearNumber)" : "this service"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                Text("Other costs in \(scopeLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)

                ForEach(items) { item in
                    Button { onSelectItem(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.costItemName)
                                .font(.caption)
                                .foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            Text(WarrantySupport.costCaption(for: item))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    WarrantySupport.hasRecordedCost(for: item)
                                        ? Color.primary
                                        : AppColors.purple
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.costItemName), \(WarrantySupport.costCaption(for: item))")
                }

                if let total = WarrantySupport.combinedCost(for: event, items: items) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Year total")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(Formatters.currency(total))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.primary)
                }
            }

            Button(action: onAddItem) {
                Label(items.isEmpty ? "Add cost to \(scopeLabel)" : "Add another cost", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.purple)
        }
        .padding(items.isEmpty ? 0 : AppScreenMetrics.controlSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !items.isEmpty {
                RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous)
                    .fill(LyneqoTheme.softTeal.opacity(0.35))
            }
        }
    }
}

// MARK: - Plan editor

private struct WarrantyPlanEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let profile: VehicleProfile
    let plan: WarrantyPlan?
    var onSaved: (() -> Void)?

    @State private var isUnderWarranty: Bool
    @State private var hasExpiryDate: Bool
    @State private var warrantyExpiryDate: Date
    @State private var manufacturer: String
    @State private var modelYearText: String
    @State private var purchaseDate: Date
    @State private var purchaseCondition: WarrantyPurchaseCondition
    @State private var ownershipType: WarrantyOwnershipType
    @State private var warrantyType: String
    @State private var durationYears: Int
    @State private var handbookNotes: String
    @State private var selectedTemplateID: String
    @State private var selectedMOTClass: UKMotorhomeMOTClass
    @State private var showInfo = false
    @State private var showMOTClassInfo = false

    init(profile: VehicleProfile, plan: WarrantyPlan?, onSaved: (() -> Void)? = nil) {
        self.profile = profile
        self.plan = plan
        self.onSaved = onSaved
        _isUnderWarranty = State(initialValue: plan?.isUnderWarranty ?? true)
        _hasExpiryDate = State(initialValue: plan?.warrantyExpiryDate != nil)
        _warrantyExpiryDate = State(initialValue: plan?.warrantyExpiryDate ?? Date())
        _manufacturer = State(initialValue: Self.initialManufacturer(plan: plan, profile: profile))
        _modelYearText = State(initialValue: Self.initialModelYearText(plan: plan, profile: profile))
        _purchaseDate = State(initialValue: plan?.purchaseDate ?? Date())
        _purchaseCondition = State(initialValue: plan?.purchaseCondition ?? .newPurchase)
        _ownershipType = State(initialValue: plan?.ownershipType ?? .original)
        _warrantyType = State(initialValue: plan?.warrantyType ?? "")
        _durationYears = State(initialValue: plan?.durationYears ?? WarrantySupport.defaultDurationYears)
        _handbookNotes = State(initialValue: plan?.handbookNotes ?? "")
        _selectedTemplateID = State(initialValue: plan?.templateID ?? WarrantySupport.customTemplateID)
        _selectedMOTClass = State(
            initialValue: plan?.motClass ?? WarrantySupport.suggestedMOTClass(for: profile)
        )
    }

    private func applyPatternDefaults(patternID: String) {
        let pattern = WarrantySupport.patternOrCustom(id: patternID, kind: profile.kind)
        durationYears = pattern.durationYears
        if !pattern.manufacturerName.isEmpty {
            manufacturer = pattern.manufacturerName
        }
    }

    private var availableTemplates: [WarrantyManufacturerTemplate] {
        WarrantySupport.pickerOptions(for: profile)
    }

    private var usesUKStarters: Bool {
        WarrantySupport.usesUKManufacturerStarters(for: profile)
    }

    private var selectedPattern: WarrantyManufacturerTemplate {
        WarrantySupport.patternOrCustom(id: selectedTemplateID, kind: profile.kind)
    }

    private var showsUKMOTClassPicker: Bool {
        profile.kind == .motorhome && profile.warrantyUKMarket
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "shield.fill",
                        title: plan == nil ? "Service timeline setup" : "Edit service plan",
                        subtitle: "One continuous record of services for this \(profile.kind.displayName.lowercased()). Warranty cover is optional."
                    )

                    WarrantyDisclaimerInfoButton { showInfo = true }

                    AppSettingsSection("Coverage") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            Toggle("Manufacturer or dealer may pay for services", isOn: $isUnderWarranty)
                            Text(isUnderWarranty
                                ? "Services still belong on the timeline. This only records that cover may pay for them."
                                : "Same services still need doing. Keep logging them on the timeline for your records and when selling.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSupporting)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Set explicit expiry date", isOn: $hasExpiryDate)
                            if hasExpiryDate {
                                DatePicker("Warranty expires", selection: $warrantyExpiryDate, displayedComponents: .date)
                            }
                        }
                    }

                    AppSettingsSection(
                        usesUKStarters ? "Manufacturer starter" : "Custom plan",
                        caption: usesUKStarters
                            ? "UK / NI starter schedules only — confirm with your handbook. Change market in Settings if this vehicle was sold outside the UK."
                            : "Manufacturer starters are for the UK / Northern Ireland market. Build your own schedule from your local handbook, then edit each event."
                    ) {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            if usesUKStarters {
                                Picker("Manufacturer", selection: $selectedTemplateID) {
                                    ForEach(availableTemplates) { option in
                                        Text(option.displayName).tag(option.id)
                                    }
                                }

                                Text(selectedPattern.summary)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(WarrantySupport.starterDisclaimer)
                                    .font(.caption2)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Custom plan — set duration and edit each year’s window and requirements after creation.")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .onChange(of: selectedTemplateID) { _, newValue in
                        applyPatternDefaults(patternID: newValue)
                    }
                    .onAppear {
                        if !usesUKStarters {
                            selectedTemplateID = WarrantySupport.customTemplateID
                        } else if !availableTemplates.contains(where: { $0.id == selectedTemplateID }) {
                            selectedTemplateID = WarrantySupport.customTemplateID
                        }
                    }

                    if showsUKMOTClassPicker {
                        AppSettingsSection(
                            "UK MOT class",
                            caption: "Drives when statutory tests are added to the timeline. Suggested from plated MAM when available — confirm with your V5C."
                        ) {
                            VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                                HStack(alignment: .center, spacing: AppScreenMetrics.smallSpacing) {
                                    Picker("MOT class", selection: $selectedMOTClass) {
                                        ForEach(UKMotorhomeMOTClass.allCases) { option in
                                            Text(option.displayName).tag(option)
                                        }
                                    }

                                    Button {
                                        showMOTClassInfo = true
                                    } label: {
                                        Image(systemName: "info.circle")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Color.secondary)
                                            .frame(minWidth: 44, minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("About MOT types")
                                    .accessibilityHint("Explains Class 4, Class 7, and HGV annual tests")
                                }

                                Text(selectedMOTClass.summary)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text("First test: year \(selectedMOTClass.firstTestYear), then annually.")
                                    .font(.caption2)
                                    .foregroundStyle(AppColors.textSupporting)
                            }
                        }
                    }

                    if VehicleLookupDisplay.hasSummary(for: profile) {
                        VehicleLookupSummarySection(profile: profile)
                    }

                    AppSettingsSection("Vehicle context") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            AppLabeledTextField("Manufacturer", placeholder: "e.g. Swift", text: $manufacturer)
                            AppLabeledTextField("Model year", placeholder: "e.g. 2022", text: $modelYearText, keyboard: .numberPad)
                            DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                            Picker("Purchase condition", selection: $purchaseCondition) {
                                ForEach(WarrantyPurchaseCondition.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            Picker("Ownership", selection: $ownershipType) {
                                ForEach(WarrantyOwnershipType.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            if ownershipType == .subsequent {
                                Text("Subsequent ownership can change remaining cover. Check your handbook and adjust duration yourself.")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            AppLabeledTextField("Warranty type", placeholder: "e.g. Structural", text: $warrantyType)
                            Stepper("Duration: \(durationYears) years", value: $durationYears, in: 1...20)
                        }
                    }

                    AppSettingsSection("Handbook notes") {
                        TextEditor(text: $handbookNotes)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(LyneqoTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous))
                    }

                    AppPrimaryButton(plan == nil ? "Create plan" : "Save changes", systemImage: "checkmark.circle.fill") {
                        save()
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle(plan == nil ? "Set Up Timeline" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showInfo) {
                WarrantyInfoSheet()
            }
            .sheet(isPresented: $showMOTClassInfo) {
                MOTClassInfoSheet()
            }
        }
    }

    private static func initialManufacturer(plan: WarrantyPlan?, profile: VehicleProfile) -> String {
        let existing = plan?.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty { return existing }
        return profile.manufacturer
    }

    private static func initialModelYearText(plan: WarrantyPlan?, profile: VehicleProfile) -> String {
        if let year = plan?.modelYear { return String(year) }
        if let year = profile.firstRegistrationYear { return String(year) }
        return ""
    }

    private func save() {
        let target = plan ?? WarrantyStore.createPlan(for: profile.id, in: modelContext)
        let modelYear = Int(modelYearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let templateID: String? = {
            guard usesUKStarters else { return nil }
            return selectedTemplateID == WarrantySupport.customTemplateID ? nil : selectedTemplateID
        }()
        let template = WarrantySupport.patternOrCustom(id: templateID, kind: profile.kind)
        let resolvedManufacturer: String = {
            let typed = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { return typed }
            return template.manufacturerName
        }()
        WarrantyStore.save(
            plan: target,
            isUnderWarranty: isUnderWarranty,
            warrantyExpiryDate: hasExpiryDate ? warrantyExpiryDate : nil,
            manufacturer: resolvedManufacturer,
            modelYear: modelYear,
            purchaseDate: purchaseDate,
            purchaseCondition: purchaseCondition,
            ownershipType: ownershipType,
            warrantyType: warrantyType,
            durationYears: durationYears,
            handbookNotes: handbookNotes,
            templateID: templateID,
            motClass: showsUKMOTClassPicker ? selectedMOTClass : nil,
            in: modelContext
        )
        WarrantyStore.syncInsuranceRenewalEvents(for: profile, in: modelContext)
        onSaved?()
        dismiss()
    }
}

// MARK: - Event editor

struct WarrantyEventEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var documentRecords: [DocumentRecord]

    let plan: WarrantyPlan
    let event: WarrantyEvent?
    let costItemFor: WarrantyEvent?

    @State private var scheduledDate: Date
    @State private var daysBefore: Int
    @State private var daysAfter: Int
    @State private var serviceType: WarrantyServiceType
    @State private var requirementDescription: String
    @State private var hasCompletedDate: Bool
    @State private var completedDate: Date
    @State private var linkedDocumentIDs: Set<UUID>
    @State private var costText: String
    @State private var pendingAttachments: [MaintenanceAttachmentDraft] = []
    @State private var repeatYearly = false

    init(
        plan: WarrantyPlan,
        event: WarrantyEvent?,
        costItemFor: WarrantyEvent? = nil
    ) {
        self.plan = plan
        self.event = event
        self.costItemFor = costItemFor
        _scheduledDate = State(initialValue: event?.scheduledDate ?? costItemFor?.scheduledDate ?? Date())
        _daysBefore = State(initialValue: event?.daysBefore ?? (costItemFor == nil ? WarrantySupport.defaultDaysBefore : 0))
        _daysAfter = State(initialValue: event?.daysAfter ?? (costItemFor == nil ? WarrantySupport.defaultDaysAfter : 0))
        _serviceType = State(initialValue: event?.serviceType ?? (costItemFor == nil ? .normalService : .custom))
        _requirementDescription = State(initialValue: event?.requirementDescription ?? "")
        _hasCompletedDate = State(initialValue: event?.completedDate != nil)
        _completedDate = State(initialValue: event?.completedDate ?? Date())
        _linkedDocumentIDs = State(initialValue: Set(event?.linkedDocumentIDs ?? []))
        _costText = State(initialValue: event?.cost.map { Formatters.currencyInputString($0) } ?? "")
    }

    private var documents: [DocumentRecord] {
        MaintenanceSupport.documentRecords(for: plan.vehicleID, from: documentRecords)
    }

    private var isCostItem: Bool {
        event?.isCostItem == true || costItemFor != nil
    }

    private var parentEventID: UUID? {
        event?.parentEventID ?? costItemFor?.id
    }

    private var canSave: Bool {
        guard isCostItem else { return true }
        let hasName = !requirementDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCost = Formatters.parseCurrency(costText) != nil
        return hasName && hasCost
    }

    private var derivedYearNumber: Int {
        WarrantySupport.yearNumber(for: scheduledDate, purchaseDate: plan.purchaseDate)
    }

    private var yearLabelText: String {
        if derivedYearNumber > 0 {
            return "Year \(derivedYearNumber) (from due date vs purchase)"
        }
        return "Custom event (due date is not a clear service year from purchase)"
    }

    private var heroTitle: String {
        if isCostItem {
            return event == nil ? "Add item" : "Edit item"
        }
        return event == nil ? "New service event" : "Edit service event"
    }

    /// The service year an item belongs to, e.g. "year 2".
    private var costItemScopeLabel: String {
        let year = costItemFor?.yearNumber ?? event?.yearNumber ?? derivedYearNumber
        return year > 0 ? "year \(year)" : "this service"
    }

    private var repeatCaption: String {
        let end = WarrantySupport.yearlyRepeatEndDate(for: plan, startingFrom: scheduledDate)
        let count = WarrantySupport.yearlyOccurrenceDates(from: scheduledDate, through: end).count
        return "Adds matching events each year from this due date through \(Formatters.date(end)) (\(count) in total, skipping any that already exist)."
    }

    private var linkableDocuments: [DocumentRecord] {
        WarrantySupport.documentsAvailableToLink(
            from: documents,
            alreadyLinkedIDs: Array(linkedDocumentIDs)
        )
    }

    private var linkedDocumentAttachments: [MaintenanceAttachment] {
        documents
            .filter { linkedDocumentIDs.contains($0.id) }
            .flatMap(\.attachmentsList)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: isCostItem ? "sterlingsign.circle" : "calendar.badge.clock",
                        title: heroTitle,
                        subtitle: isCostItem
                            ? "Something that falls in \(costItemScopeLabel), such as storage. Counts towards yearly totals — separate from warranty claims."
                            : "Set the due date, action window, and what work is required."
                    )

                    AppSettingsSection(isCostItem ? "Date" : "Schedule") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            DatePicker(isCostItem ? "Date" : "Due date", selection: $scheduledDate, displayedComponents: .date)
                            Text(yearLabelText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.textSupporting)
                            if !isCostItem {
                                Stepper("Days before: \(daysBefore)", value: $daysBefore, in: 0...365)
                                Stepper("Days after: \(daysAfter)", value: $daysAfter, in: 0...365)
                                Toggle("Repeat yearly", isOn: $repeatYearly)
                                if repeatYearly {
                                    Text(repeatCaption)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSupporting)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    AppSettingsSection(isCostItem ? "Item" : "Requirement") {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            if isCostItem {
                                AppLabeledTextField(
                                    "Item name",
                                    placeholder: "e.g. Storage",
                                    text: $requirementDescription
                                )
                            } else {
                                Picker("Service type", selection: $serviceType) {
                                    ForEach(WarrantyServiceType.allCases) { option in
                                        Text(option.displayName).tag(option)
                                    }
                                }
                                .onChange(of: serviceType) { _, newValue in
                                    if requirementDescription.isEmpty || WarrantyServiceType.allCases.map(\.defaultRequirementDescription).contains(requirementDescription) {
                                        requirementDescription = newValue.defaultRequirementDescription
                                    }
                                }

                                TextEditor(text: $requirementDescription)
                                    .frame(minHeight: 100)
                                    .padding(8)
                                    .background(LyneqoTheme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.fieldCornerRadius, style: .continuous))
                            }
                        }
                    }

                    if !isCostItem {
                        AppSettingsSection("Completion") {
                            Toggle("Mark as completed", isOn: $hasCompletedDate)
                            if hasCompletedDate {
                                DatePicker("Completed date", selection: $completedDate, displayedComponents: .date)
                            }
                        }
                    }

                    AppSettingsSection("Cost") {
                        AppLabeledTextField(
                            "Cost",
                            placeholder: isCostItem ? "e.g. 100" : "e.g. 350",
                            text: $costText,
                            keyboard: .decimalPad
                        )
                    }

                    AppSettingsSection(
                        "Documents",
                        caption: "Files added here are also stored in Documents. You can link paperwork you already added there."
                    ) {
                        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                            if linkableDocuments.isEmpty {
                                Text("No documents yet. Add a file below, or create one in Documents and link it here.")
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(linkableDocuments) { doc in
                                    Toggle(isOn: Binding(
                                        get: { linkedDocumentIDs.contains(doc.id) },
                                        set: { isOn in
                                            if isOn { linkedDocumentIDs.insert(doc.id) }
                                            else { linkedDocumentIDs.remove(doc.id) }
                                        }
                                    )) {
                                        Text(doc.title.isEmpty ? doc.category.displayName : doc.title)
                                            .font(.subheadline)
                                    }
                                }
                            }

                            WarrantyEventAttachmentSection(
                                event: event,
                                linkedAttachments: linkedDocumentAttachments,
                                pendingAttachments: $pendingAttachments
                            )
                        }
                    }

                    AppPrimaryButton(
                        event == nil ? (isCostItem ? "Add item" : "Save event") : "Save changes",
                        systemImage: "checkmark.circle.fill"
                    ) {
                        save()
                    }
                    .disabled(!canSave)

                    if event != nil {
                        Button(isCostItem ? "Delete item" : "Delete event", role: .destructive) {
                            if let event { WarrantyStore.delete(event: event, in: modelContext) }
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle(isCostItem ? (event == nil ? "Add Item" : "Edit Item") : (event == nil ? "Add Event" : "Edit Event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if let event {
                    WarrantyStore.promoteEventAttachmentsToDocuments(events: [event], in: modelContext)
                    linkedDocumentIDs = Set(event.linkedDocumentIDs)
                }
            }
        }
    }

    private func save() {
        let target = event ?? WarrantyStore.createEvent(for: plan, in: modelContext)
        let sortOrder = event?.sortOrder ?? ((plan.events ?? []).map(\.sortOrder).max() ?? 0) + 1
        let requirement = requirementDescription.isEmpty
            ? serviceType.defaultRequirementDescription
            : requirementDescription
        WarrantyStore.save(
            event: target,
            yearNumber: derivedYearNumber,
            scheduledDate: scheduledDate,
            daysBefore: daysBefore,
            daysAfter: daysAfter,
            serviceType: serviceType,
            requirementDescription: requirement,
            sortOrder: sortOrder,
            isManual: event?.isManual ?? true,
            completedDate: hasCompletedDate ? completedDate : nil,
            linkedDocumentIDs: Array(linkedDocumentIDs),
            linkedMaintenanceID: target.linkedMaintenanceID,
            linkedFaultID: target.linkedFaultID,
            parentEventID: parentEventID,
            cost: Formatters.parseCurrency(costText),
            in: modelContext
        )
        if !pendingAttachments.isEmpty {
            WarrantyStore.attachDrafts(pendingAttachments, to: target, in: modelContext)
        }
        if repeatYearly {
            WarrantyStore.ensureYearlyRepeats(for: plan, matching: target, in: modelContext)
        }
        dismiss()
    }
}

private struct WarrantyEventAttachmentSection: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var sidecarPhotos = CloudKitSidecarPhotoSync.shared

    let event: WarrantyEvent?
    let linkedAttachments: [MaintenanceAttachment]
    @Binding var pendingAttachments: [MaintenanceAttachmentDraft]

    @State private var showSourceDialog = false
    @State private var showLibraryPicker = false
    @State private var showFileImporter = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var previewAttachment: AttachmentPreviewSource?

    private var existingAttachments: [MaintenanceAttachment] {
        let eventOwned = event?.attachmentsList ?? []
        var seen = Set(eventOwned.map(\.id))
        var combined = eventOwned
        for attachment in linkedAttachments where seen.insert(attachment.id).inserted {
            combined.append(attachment)
        }
        return combined
    }

    var body: some View {
        let _ = sidecarPhotos.revision
        VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                if existingAttachments.isEmpty && pendingAttachments.isEmpty {
                    Text("No files attached to this event yet.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSupporting)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppScreenMetrics.controlSpacing) {
                            ForEach(existingAttachments) { attachment in
                                AttachmentThumbnailView(
                                    title: attachment.displayName,
                                    image: MaintenanceAttachmentStore.loadThumbnail(for: attachment),
                                    symbolName: symbolName(for: attachment.fileType)
                                ) {
                                    previewAttachment = .saved(attachment)
                                } onDelete: {
                                    MaintenanceAttachmentStore.delete(attachment, in: modelContext)
                                }
                            }

                            ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, draft in
                                AttachmentThumbnailView(
                                    title: draft.displayName,
                                    image: draft.thumbnailImage ?? previewImage(for: draft),
                                    symbolName: symbolName(for: draft.fileType)
                                ) {
                                    previewAttachment = .pending(draft)
                                } onDelete: {
                                    pendingAttachments.remove(at: index)
                                }
                            }
                        }
                    }
                }

                AppSecondaryButton("Add file") {
                    showSourceDialog = true
                }
        }
        .confirmationDialog("Add file", isPresented: $showSourceDialog) {
            Button("Choose From Photos") { showLibraryPicker = true }
            Button("Choose From Files") { showFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibraryPicker, selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var drafts: [MaintenanceAttachmentDraft] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let draft = try? MaintenanceAttachmentStore.draft(image: image, fileType: .photo, displayName: "Photo") {
                        drafts.append(draft)
                    }
                }
                await MainActor.run {
                    pendingAttachments.append(contentsOf: drafts)
                    selectedPhotoItems = []
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image, .item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            pendingAttachments.append(contentsOf: urls.compactMap { try? MaintenanceAttachmentStore.draft(fileAt: $0) })
        }
        .sheet(item: $previewAttachment) { preview in
            AttachmentPreviewView(preview: preview)
        }
        .onAppear {
            for attachment in existingAttachments {
                CloudKitSidecarPhotoSync.shared.downloadAttachmentIfNeeded(attachment)
            }
        }
    }

    private func previewImage(for draft: MaintenanceAttachmentDraft) -> UIImage? {
        if draft.fileType == .pdf {
            return MaintenanceAttachmentStore.pdfThumbnail(for: draft.data, maxDimension: 400)
        }
        return UIImage(data: draft.data)
    }

    private func symbolName(for kind: MaintenanceAttachmentKind) -> String {
        switch kind {
        case .photo:
            return "photo"
        case .scannedDocument:
            return "doc.text.viewfinder"
        case .pdf:
            return "doc.richtext"
        case .file:
            return "doc"
        }
    }
}

private struct WarrantyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "info.circle.fill",
                        title: "About service & warranty",
                        subtitle: "One timeline for the life of the vehicle. Warranty is optional cover for the same services."
                    )
                    Text("Whether a manufacturer pays or you do, annual services, inspections and repairs belong on this timeline. If cover expires or a claim is refused, keep logging the same work — it remains useful when you sell.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                    WarrantyDisclaimerBanner()
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
            }
            .appScreenBackground()
            .navigationTitle("Service & warranty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct MOTClassInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "info.circle.fill",
                        title: "UK MOT types",
                        subtitle: "Choose the class that matches your motorhome’s plated mass and body type. Always confirm with your V5C and test station."
                    )

                    ForEach(UKMotorhomeMOTClass.allCases) { motClass in
                        AppGroupedCard {
                            VStack(alignment: .leading, spacing: AppScreenMetrics.fieldSpacing) {
                                Text(motClass.displayName)
                                    .font(.headline.weight(.semibold))
                                Text(motClass.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textSupporting)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("First test: year \(motClass.firstTestYear), then annually.")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textSupporting)
                            }
                        }
                    }

                    Text("Lyneqo suggests a class from plated MAM when available, but some vehicles in the 3,000–3,500 kg band remain Class 4 depending on body type. Edit the class if your handbook or test station says otherwise.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("MOT types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct WarrantyPDFShareItem: Identifiable {
    let id = UUID()
    let data: Data
}

private struct WarrantyEvidenceShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pdfData: Data

    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: AppScreenMetrics.sectionSpacing) {
                Text("Your warranty evidence pack is ready to share or save. It includes the service timeline and any photographs attached to service events.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSupporting)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                PDFDocumentView(data: pdfData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius, style: .continuous))
                    .padding(.horizontal)

                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share evidence pack", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cornerRadius))
                    }
                    .padding(.horizontal)
                } else {
                    Text("Could not prepare the evidence pack for sharing.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                }
            }
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                guard shareURL == nil else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Warranty-Evidence-Pack-\(UUID().uuidString).pdf")
                do {
                    try pdfData.write(to: url, options: .atomic)
                    shareURL = url
                } catch {
                    shareURL = nil
                }
            }
        }
    }
}
