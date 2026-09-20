import SwiftData
import SwiftUI

struct TripRecordEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTrips: [Trip]

    @State private var draft: TripRecordDraft
    private let original: TripRecordDraft
    var onCancel: () -> Void
    var onSave: (TripRecord) -> Void

    @State private var showValidation = false
    @State private var validationMessage = ""
    @State private var confirmDiscard = false

    init(
        draft: TripRecordDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (TripRecord) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.original = draft
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var isNew: Bool {
        draft.existingID == nil
    }

    private var isDirty: Bool {
        draft != original
    }

    private var loadingConfigurations: [Trip] {
        allTrips
            .filter { $0.profile?.id == draft.vehicleProfileID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                routeSection
                expensesSection
            }
            .navigationTitle(isNew ? "New trip" : "Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty {
                            confirmDiscard = true
                        } else {
                            onCancel()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert("Check these details", isPresented: $showValidation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive, action: onCancel)
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("This trip has not been saved.")
            }
        }
    }

    private var detailsSection: some View {
        Section("Trip") {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)

            TextField(
                "Starting from",
                text: Binding(
                    get: { draft.originName },
                    set: { newValue in
                        draft.originName = newValue
                        if !draft.legs.isEmpty {
                            draft.legs[0].fromName = newValue
                        }
                        TripRecordSupport.syncRoutePlaces(in: &draft)
                    }
                )
            )
            .textInputAutocapitalization(.words)

            DatePicker("Start", selection: $draft.startDate, displayedComponents: .date)
            DatePicker("Finish", selection: $draft.endDate, displayedComponents: .date)

            if !loadingConfigurations.isEmpty {
                Picker("Loading Configuration", selection: $draft.loadingConfigurationID) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(loadingConfigurations) { trip in
                        Text(trip.name).tag(Optional(trip.id))
                    }
                }
            }

            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...8)
        }
    }

    private var routeSection: some View {
        Section {
            ForEach(TripRecordSupport.routeCards(from: draft)) { card in
                switch card {
                case .journey(let id, let number):
                    if let index = draft.legs.firstIndex(where: { $0.id == id }) {
                        journeyEditor(index: index, number: number)
                    }
                case .stay(let id, let number, _):
                    if let index = draft.stops.firstIndex(where: { $0.id == id }) {
                        stayEditor(index: index, number: number)
                    }
                }
            }

            Button {
                TripRecordSupport.appendJourney(to: &draft)
            } label: {
                Label("Add journey", systemImage: "arrow.right.circle")
            }

            Button {
                TripRecordSupport.appendStay(to: &draft)
            } label: {
                Label("Add stay", systemImage: "plus.circle")
            }
        } header: {
            Text("Route")
        } footer: {
            Text("The trip can be just the overall holiday journey. Add a stay only if you want to record a site. Add another journey for a later hop or the run back. Mileage and journey time are optional. Journey time can be hours:minutes (2:30) or hours (2.5). Leave a field blank if you have not recorded it yet. Zero means you entered 0.")
        }
    }

    private var expensesSection: some View {
        Section {
            ForEach($draft.expenses) { $expense in
                expenseEditor($expense)
            }
            .onDelete(perform: deleteExpenses)

            Button {
                draft.expenses.append(TripExpenseDraft())
            } label: {
                Label("Add cost", systemImage: "plus.circle")
            }
        } header: {
            Text("Costs")
        } footer: {
            Text("Fuel · Site · Tolls/Road · Ferry · Parking · Food · Activities · Other. Site fees can also be recorded on a stay.")
        }
    }

    private func journeyEditor(index: Int, number: Int) -> some View {
        let isPaired = index < TripRecordSupport.destinationCount(in: draft)
        let from = draft.legs[index].fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            HStack(spacing: AppScreenMetrics.controlSpacing) {
                Text("Journey \(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isPaired {
                    reorderButtons(index: index, count: TripRecordSupport.destinationCount(in: draft), accessibilityNoun: "destination") { from, to in
                        TripRecordSupport.moveDestination(in: &draft, from: from, to: to)
                    }
                }
                routeDeleteButton(accessibilityLabel: "Delete journey \(number)") {
                    TripRecordSupport.deleteJourney(in: &draft, id: draft.legs[index].id)
                }
            }
            .buttonStyle(.borderless)

            HStack(alignment: .bottom, spacing: AppScreenMetrics.controlSpacing) {
                VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
                    Text("From")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                    Text(from.isEmpty ? "—" : from)
                        .font(.body)
                        .foregroundStyle(from.isEmpty ? AppColors.textSupporting : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
                    .padding(.bottom, 6)

                compactRouteField(
                    "To",
                    text: Binding(
                        get: { index < draft.legs.count ? draft.legs[index].toName : "" },
                        set: { newValue in
                            guard index < draft.legs.count else { return }
                            draft.legs[index].toName = newValue
                            TripRecordSupport.syncRoutePlaces(in: &draft)
                        }
                    )
                )
                .textInputAutocapitalization(.words)

                DatePicker("Date", selection: $draft.legs[index].travelledOn, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize()
                    .padding(.bottom, 2)
            }

            HStack(alignment: .top, spacing: AppScreenMetrics.controlSpacing) {
                compactRouteField("Mileage", text: $draft.legs[index].mileageText, keyboard: .decimalPad)
                compactRouteField("Journey time", text: $draft.legs[index].travelTimeText, prompt: "3")
            }

            TextField("Journey notes", text: $draft.legs[index].notes, axis: .vertical)
                .lineLimit(2...4)
        }
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
    }

    private func stayEditor(index: Int, number: Int) -> some View {
        let slot = TripRecordSupport.moveSlot(forStayIndex: index, in: draft)
        return VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            HStack(spacing: AppScreenMetrics.controlSpacing) {
                Text("Stay \(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let slot {
                    let pairCount = TripRecordSupport.destinationCount(in: draft)
                    if case .destination(let destinationIndex) = slot {
                        reorderButtons(index: destinationIndex, count: pairCount, accessibilityNoun: "destination") { from, to in
                            TripRecordSupport.moveDestination(in: &draft, from: from, to: to)
                        }
                    }
                }
                routeDeleteButton(accessibilityLabel: "Delete stay \(number)") {
                    TripRecordSupport.deleteStay(in: &draft, id: draft.stops[index].id)
                }
            }
            .buttonStyle(.borderless)

            compactRouteField(
                "Place",
                text: Binding(
                    get: { index < draft.stops.count ? draft.stops[index].locationName : "" },
                    set: { newValue in
                        guard index < draft.stops.count else { return }
                        draft.stops[index].locationName = newValue
                        TripRecordSupport.syncRoutePlaces(in: &draft)
                    }
                )
            )
            .textInputAutocapitalization(.words)

            HStack(alignment: .bottom, spacing: AppScreenMetrics.controlSpacing) {
                compactDateField("From", selection: $draft.stops[index].arrivedAt)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSupporting)
                    .padding(.bottom, 6)
                compactDateField("To", selection: $draft.stops[index].departedAt)
            }

            TextField("Site cost", text: $draft.stops[index].siteCostText)
                .keyboardType(.decimalPad)
            TextField("Stay notes", text: $draft.stops[index].notes, axis: .vertical)
                .lineLimit(2...4)
        }
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
    }

    private func compactRouteField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default,
        prompt: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
            TextField(prompt ?? title, text: text)
                .keyboardType(keyboard)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactDateField(_ title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.tinySpacing) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppColors.textSupporting)
            DatePicker(title, selection: selection, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reorderButtons(
        index: Int,
        count: Int,
        accessibilityNoun: String,
        move: @escaping (Int, Int) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                move(index, index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Move \(accessibilityNoun) \(index + 1) up")

            Button {
                move(index, index + 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= count - 1)
            .accessibilityLabel("Move \(accessibilityNoun) \(index + 1) down")
        }
    }

    private func routeDeleteButton(accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func expenseEditor(_ expense: Binding<TripExpenseDraft>) -> some View {
        VStack(alignment: .leading, spacing: AppScreenMetrics.smallSpacing) {
            Picker("Category", selection: expense.category) {
                ForEach(TripExpenseCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }
            DatePicker("Date", selection: expense.date, displayedComponents: .date)
            TextField("Amount", text: expense.amountText)
                .keyboardType(.decimalPad)
            TextField("Cost notes", text: expense.notes, axis: .vertical)
                .lineLimit(2...4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func deleteExpenses(at offsets: IndexSet) {
        draft.expenses.remove(atOffsets: offsets)
    }

    private func save() {
        TripRecordSupport.syncRoutePlaces(in: &draft)
        let issues = TripRecordDraft.validate(draft)
        if !issues.isEmpty {
            validationMessage = issues.map(\.message).joined(separator: "\n")
            showValidation = true
            return
        }
        do {
            let record = try TripRecordStore.save(draft, in: modelContext)
            onSave(record)
        } catch {
            validationMessage = error.localizedDescription
            showValidation = true
        }
    }
}

