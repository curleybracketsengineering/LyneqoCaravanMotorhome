import SwiftData
import SwiftUI

struct DocumentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.padTopTabBarActive) private var padTopTabBarActive
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @Query private var documentRecords: [DocumentRecord]
    @Query private var warrantyPlans: [WarrantyPlan]

    @State private var searchText = ""
    @State private var showCreate = false
    @State private var selectedRecord: DocumentRecord?

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(profiles: profiles, appState: AppStateStore.canonical(from: appStates))
    }

    private var scopedDocuments: [DocumentRecord] {
        guard let profile = activeProfile else { return [] }
        return MaintenanceSupport.documentRecords(for: profile.id, from: documentRecords)
    }

    private var scopedServiceEvents: [WarrantyEvent] {
        guard let profile = activeProfile else { return [] }
        return warrantyPlans
            .filter { $0.vehicleID == profile.id }
            .flatMap(\.eventsList)
    }

    private var filteredDocuments: [DocumentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = scopedDocuments.sorted {
            if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
            return displayTitle(for: $0).localizedCaseInsensitiveCompare(displayTitle(for: $1)) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { record in
            let linkedTitles = WarrantySupport.linkedEventTitles(for: record.id, from: scopedServiceEvents)
                .joined(separator: " ")
            return [
                displayTitle(for: record),
                record.category.displayName,
                record.notes,
                linkedTitles
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    var body: some View {
        Group {
            if activeProfile != nil {
                documentsContent
            } else {
                ContentUnavailableView(
                    "No vehicle selected",
                    systemImage: "folder.fill",
                    description: Text("Choose a vehicle to view its documents.")
                )
            }
        }
        .appScreenBackground()
        .modifier(DocumentsNavigationChrome(isPadTab: padTopTabBarActive))
        .searchable(text: $searchText, prompt: "Search documents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(activeProfile == nil)
                .accessibilityLabel("Add document")
            }
        }
        .sheet(isPresented: $showCreate) {
            if let profile = activeProfile {
                DocumentRecordEditorView(profile: profile, serviceEvents: scopedServiceEvents)
            }
        }
        .sheet(item: $selectedRecord) { record in
            if let profile = activeProfile {
                DocumentRecordEditorView(profile: profile, record: record, serviceEvents: scopedServiceEvents)
            }
        }
        .onAppear {
            WarrantyStore.promoteEventAttachmentsToDocuments(events: scopedServiceEvents, in: modelContext)
        }
    }

    private var documentsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                AppHeroSection(
                    systemImage: "folder.fill",
                    title: "Documents",
                    subtitle: "Insurance, registration, manuals, photos and scanned paperwork stored with this vehicle."
                )

                if filteredDocuments.isEmpty {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSupporting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppScreenMetrics.cardInteriorPadding)
                        .background(LyneqoTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous))
                } else {
                    LazyVStack(spacing: AppScreenMetrics.controlSpacing) {
                        ForEach(filteredDocuments) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                DocumentsRowView(
                                    record: record,
                                    linkedEventTitles: WarrantySupport.linkedEventTitles(
                                        for: record.id,
                                        from: scopedServiceEvents
                                    )
                                )
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
    }

    private var emptyMessage: String {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No documents stored yet. Add insurance, registration, manuals, photos or scanned paperwork."
        }
        return "No documents match your search."
    }

    private func displayTitle(for record: DocumentRecord) -> String {
        record.title.isEmpty ? record.category.displayName : record.title
    }
}

private struct DocumentsNavigationChrome: ViewModifier {
    let isPadTab: Bool

    func body(content: Content) -> some View {
        if isPadTab {
            content.appPrincipalTabTitle("Documents")
        } else {
            content
                .navigationTitle("Documents")
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct DocumentsRowView: View {
    let record: DocumentRecord
    var linkedEventTitles: [String] = []

    private var title: String {
        record.title.isEmpty ? record.category.displayName : record.title
    }

    private var attachmentCount: Int {
        record.attachmentsList.count
    }

    private var thumbnail: UIImage? {
        guard let attachment = record.attachmentsList.first else { return nil }
        return MaintenanceAttachmentStore.loadThumbnail(for: attachment)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
            documentGlyph
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .multilineTextAlignment(.leading)

                if let expiryDate = record.expiryDate {
                    Text("Expires \(Formatters.date(expiryDate))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(expiryTint(for: expiryDate))
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.top, 4)
        }
        .padding(AppScreenMetrics.cardInteriorPadding)
        .background(LyneqoTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: AppScreenMetrics.cardCornerRadiusLarge, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var documentGlyph: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                AppColors.orange.opacity(0.15)
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(AppColors.orange)
            }
        }
    }

    private var subtitle: String {
        var parts = [record.category.displayName, Formatters.date(record.dateAdded)]
        if attachmentCount > 0 {
            parts.append("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")")
        }
        if let linked = WarrantySupport.linkedServiceYearLabel(from: linkedEventTitles) {
            parts.append(linked)
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        guard let kind = record.attachmentsList.first?.fileType else {
            return "doc.text.fill"
        }
        switch kind {
        case .photo: return "photo.fill"
        case .scannedDocument: return "doc.text.viewfinder"
        case .pdf: return "doc.richtext.fill"
        case .file: return "doc.fill"
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, record.category.displayName, "Added \(Formatters.date(record.dateAdded))"]
        if attachmentCount > 0 {
            parts.append("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")")
        }
        if let expiryDate = record.expiryDate {
            parts.append("Expires \(Formatters.date(expiryDate))")
        }
        if let linked = WarrantySupport.linkedServiceYearLabel(from: linkedEventTitles) {
            parts.append("Linked to \(linked)")
        }
        return parts.joined(separator: ", ")
    }

    private func expiryTint(for date: Date) -> Color {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        if days < 0 { return AppColors.red }
        if days <= 30 { return AppColors.orange }
        return AppColors.textSupporting
    }
}
