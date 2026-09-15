import Foundation

struct WarrantyTemplateOption: Identifiable {
    let id: String
    let displayName: String
    let manufacturer: String
}

struct WarrantyReminderItem: Identifiable {
    let id: String
    let title: String
    let dueDate: Date
    let subtitle: String
    let eventID: UUID
}

enum WarrantySupport {
    static let defaultDurationYears = 8
    static let defaultDaysBefore = 60
    static let defaultDaysAfter = 30

    /// Reminder window ahead of the insurance anniversary.
    static let insuranceRenewalDaysBefore = 30
    static let insuranceRenewalDaysAfter = 0

    /// Starter statutory inspection schedule for non-UK motorhomes (confirm local rules).
    static let motorhomeVehicleInspectionFirstYear = 3
    static let motorhomeVehicleInspectionDaysBefore = 30
    static let motorhomeVehicleInspectionDaysAfter = 0

    static func insuranceRenewalRequirement(for kind: VehicleKind) -> String {
        switch kind {
        case .caravan:
            return "Ensure your vehicle, ensure your reg, ensure your caravan."
        case .motorhome:
            return "Ensure your vehicle, ensure your reg, ensure your motorhome."
        }
    }

    /// Inclusive yearly insurance dates from the policy start through at least 10 years ahead of today.
    static func insuranceRenewalDates(from start: Date, now: Date = Date()) -> [Date] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: now)
        let decadeFromStart = calendar.date(byAdding: .year, value: 10, to: startDay) ?? startDay
        let decadeFromToday = calendar.date(byAdding: .year, value: 10, to: today) ?? today
        let end = max(decadeFromStart, decadeFromToday)
        return yearlyOccurrenceDates(from: startDay, through: end)
    }

    static func suggestedMOTClass(for profile: VehicleProfile) -> UKMotorhomeMOTClass {
        UKMotorhomeMOTClass.suggested(forPlatedMassKg: profile.mtplmKg)
    }

    static let warrantyDisclaimer = """
    Lyneqo Caravan & Motorhome helps you organise warranty-related records and reminders. It cannot confirm warranty coverage, interpret manufacturer terms, or guarantee that a claim will be accepted. Always follow your owner's handbook and manufacturer instructions. If in doubt, contact your dealer or manufacturer directly.
    """

    static let customTemplateID = WarrantyPatternCatalog.customID

    static let starterDisclaimer = WarrantyPatternCatalog.starterDisclaimer

    static let templateOptions: [WarrantyTemplateOption] = {
        WarrantyPatternCatalog.pickerOptions.map {
            WarrantyTemplateOption(
                id: $0.id,
                displayName: $0.displayName,
                manufacturer: $0.manufacturerName
            )
        }
    }()

    static func patternOrCustom(id: String?, kind: VehicleKind) -> WarrantyManufacturerTemplate {
        switch kind {
        case .caravan:
            return WarrantyPatternCatalog.patternOrCustom(id: id)
        case .motorhome:
            return MotorhomeWarrantyPatternCatalog.patternOrCustom(id: id)
        }
    }

    static func patternSummary(for templateID: String?, kind: VehicleKind) -> String {
        patternOrCustom(id: templateID, kind: kind).summary
    }

    static func manufacturerTemplate(for templateID: String?, kind: VehicleKind) -> WarrantyManufacturerTemplate? {
        let template = patternOrCustom(id: templateID, kind: kind)
        return template.isCustom ? nil : template
    }

    static func showsWarrantyFeatures(for profile: VehicleProfile?) -> Bool {
        profile?.warrantyAvailable ?? true
    }

    static func usesUKManufacturerStarters(for profile: VehicleProfile?) -> Bool {
        (profile?.warrantyAvailable ?? true) && (profile?.warrantyUKMarket ?? true)
    }

    static func pickerOptions(for profile: VehicleProfile?) -> [WarrantyManufacturerTemplate] {
        let kind = profile?.kind ?? .caravan
        if usesUKManufacturerStarters(for: profile) {
            switch kind {
            case .caravan:
                return WarrantyPatternCatalog.pickerOptions
            case .motorhome:
                return MotorhomeWarrantyPatternCatalog.pickerOptions
            }
        }
        return [patternOrCustom(id: customTemplateID, kind: kind)]
    }

    static func plan(for vehicleID: UUID, from plans: [WarrantyPlan]) -> WarrantyPlan? {
        let matches = plans.filter { $0.vehicleID == vehicleID }
        return matches.max(by: { retentionScore(for: $0) < retentionScore(for: $1) })
    }

    /// Prefers a plan with completed work, photos, and costs over an empty generated template.
    static func retentionScore(for plan: WarrantyPlan) -> Int {
        let events = plan.eventsList
        var score = 0
        score += events.filter { $0.completedDate != nil }.count * 1_000
        score += events.reduce(0) { $0 + $1.attachmentsList.count } * 400
        score += events.filter { ($0.actualCost ?? 0) > 0 }.count * 300
        score += events.filter(\.isManual).count * 200
        score += events.filter { !$0.isCostItem }.count * 10
        if !plan.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 5
        }
        score += Int(plan.updatedAt.timeIntervalSince1970 / 1_000_000)
        return score
    }

    static func events(for vehicleID: UUID, from plans: [WarrantyPlan]) -> [WarrantyEvent] {
        plan(for: vehicleID, from: plans)?.eventsList ?? []
    }

    static func expiresOn(plan: WarrantyPlan) -> Date? {
        if let expiry = plan.warrantyExpiryDate {
            return expiry
        }
        return Calendar.current.date(byAdding: .year, value: plan.durationYears, to: plan.purchaseDate)
    }

    /// Year label for a service event from purchase date to due date (0 = custom / not a clear year anniversary).
    static func yearNumber(for scheduledDate: Date, purchaseDate: Date) -> Int {
        let calendar = Calendar.current
        let purchase = calendar.startOfDay(for: purchaseDate)
        let due = calendar.startOfDay(for: scheduledDate)
        guard due > purchase else { return 0 }

        let components = calendar.dateComponents([.year, .month, .day], from: purchase, to: due)
        let years = components.year ?? 0
        guard years > 0 else { return 0 }

        // Prefer the anniversary year when the due date is within ~6 months of purchase + N years.
        let months = components.month ?? 0
        let days = components.day ?? 0
        if months > 6 || (months == 6 && days > 0) {
            return years + 1
        }
        return years
    }

    static func isCoverageActive(plan: WarrantyPlan, now: Date = Date()) -> Bool {
        guard plan.isUnderWarranty else { return false }
        guard let expiry = expiresOn(plan: plan) else { return plan.isUnderWarranty }
        return now.startOfDay <= expiry.startOfDay
    }

    static func coverageStatusText(plan: WarrantyPlan?, now: Date = Date()) -> (title: String, detail: String, tintIsPositive: Bool) {
        guard let plan else {
            return ("Service timeline not set up", "Create a plan to track annual services, inspections and warranty cover.", false)
        }

        if !plan.isUnderWarranty {
            return (
                "Owner-funded servicing",
                "Not marked as under warranty. Keep logging services on the timeline — the same work still needs doing.",
                false
            )
        }

        if isCoverageActive(plan: plan, now: now), let expiry = expiresOn(plan: plan) {
            return (
                "Under warranty",
                "Cover recorded until \(Formatters.date(expiry)). Services still go on this timeline whether the manufacturer pays or not.",
                true
            )
        }

        if let expiry = expiresOn(plan: plan) {
            return (
                "Warranty ended",
                "Cover ended \(Formatters.date(expiry)). Keep using this timeline for ongoing services and repairs.",
                false
            )
        }

        return ("Under warranty", "Coverage recorded. Keep logging every service on this timeline.", true)
    }

    static func reminderItems(
        plans: [WarrantyPlan],
        vehicleID: UUID,
        now: Date = Date()
    ) -> [WarrantyReminderItem] {
        guard let plan = plan(for: vehicleID, from: plans) else {
            return []
        }

        return plan.timelineEvents.compactMap { event in
            guard event.completedDate == nil else { return nil }
            let due = reminderDate(for: event)
            return WarrantyReminderItem(
                id: "warranty-\(event.id.uuidString)",
                title: event.displayTitle,
                dueDate: due,
                subtitle: event.requirementText,
                eventID: event.id
            )
        }
        .sorted { $0.dueDate < $1.dueDate }
    }

    static func windowStart(for event: WarrantyEvent) -> Date {
        Calendar.current.date(byAdding: .day, value: -event.daysBefore, to: event.scheduledDate.startOfDay) ?? event.scheduledDate
    }

    static func windowEnd(for event: WarrantyEvent) -> Date {
        Calendar.current.date(byAdding: .day, value: event.daysAfter, to: event.scheduledDate.startOfDay) ?? event.scheduledDate
    }

    static func status(
        for event: WarrantyEvent,
        among events: [WarrantyEvent] = [],
        now: Date = Date()
    ) -> WarrantyEventStatus {
        let base = baseStatus(for: event, now: now)
        guard base == .upcoming else { return base }

        // Without sibling context, keep calling a future event "Upcoming".
        guard !events.isEmpty else { return .upcoming }

        let nextUpcomingID = events
            .filter { baseStatus(for: $0, now: now) == .upcoming }
            .sorted {
                let lhs = reminderDate(for: $0)
                let rhs = reminderDate(for: $1)
                if lhs != rhs { return lhs < rhs }
                return $0.scheduledDate < $1.scheduledDate
            }
            .first?
            .id

        return nextUpcomingID == event.id ? .upcoming : .planned
    }

    /// Status before distinguishing the next future event from later planned ones.
    private static func baseStatus(for event: WarrantyEvent, now: Date) -> WarrantyEventStatus {
        if event.completedDate != nil {
            return .completed
        }

        let today = now.startOfDay
        let windowStart = windowStart(for: event).startOfDay
        let windowEnd = windowEnd(for: event).startOfDay
        let scheduled = event.scheduledDate.startOfDay

        if today > windowEnd {
            return .overdue
        }
        if today >= windowStart && today <= windowEnd {
            return .inWindow
        }
        if today > scheduled {
            return .overdue
        }
        return .upcoming
    }

    static func statusDisplayName(for status: WarrantyEventStatus) -> String {
        switch status {
        case .completed: return "Completed"
        case .overdue: return "Overdue"
        case .inWindow: return "In window"
        case .upcoming: return "Upcoming"
        case .planned: return "Planned"
        }
    }

    static func windowSubtitle(for event: WarrantyEvent) -> String {
        if event.isImportantMilestone, event.daysAfter == 0 {
            return "Action window: \(event.daysBefore) days before – must finish on or before the anniversary (no after-grace)"
        }
        return "Action window: \(event.daysBefore) days before – \(event.daysAfter) days after due date"
    }

    static func reminderDate(for event: WarrantyEvent) -> Date {
        windowStart(for: event)
    }

    /// End date for yearly repeats: later of plan cover end and 10 years after the start date.
    static func yearlyRepeatEndDate(for plan: WarrantyPlan, startingFrom start: Date) -> Date {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let planEnd = expiresOn(plan: plan)
            ?? calendar.date(byAdding: .year, value: max(plan.durationYears, 1), to: plan.purchaseDate)
            ?? startDay
        let decadeOut = calendar.date(byAdding: .year, value: 10, to: startDay) ?? startDay
        return max(calendar.startOfDay(for: planEnd), calendar.startOfDay(for: decadeOut))
    }

    /// Inclusive yearly dates from `start` through `end` (same month/day each year).
    static func yearlyOccurrenceDates(from start: Date, through end: Date) -> [Date] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { return [] }

        var dates: [Date] = []
        var cursor = startDay
        var guardCount = 0
        while cursor <= endDay, guardCount < 40 {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .year, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
            guardCount += 1
        }
        return dates
    }

    static func nextActionableEvent(
        plans: [WarrantyPlan],
        vehicleID: UUID,
        now: Date = Date()
    ) -> WarrantyEvent? {
        guard let plan = plan(for: vehicleID, from: plans) else { return nil }

        let openEvents = plan.timelineEvents.filter { $0.completedDate == nil }
        let inWindow = openEvents.filter { status(for: $0, now: now) == .inWindow }
        if let next = inWindow.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
            return next
        }

        let overdue = openEvents.filter { status(for: $0, now: now) == .overdue }
        if let next = overdue.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
            return next
        }

        return openEvents
            .sorted { reminderDate(for: $0) < reminderDate(for: $1) }
            .first
    }

    static func careHubSubtitle(
        plans: [WarrantyPlan],
        vehicleID: UUID,
        now: Date = Date()
    ) -> String {
        guard let plan = plan(for: vehicleID, from: plans) else {
            return "Set up a service timeline for this vehicle."
        }

        if let event = nextActionableEvent(plans: plans, vehicleID: vehicleID, now: now) {
            let eventStatus = status(for: event, among: plan.eventsList, now: now)
            switch eventStatus {
            case .inWindow:
                return "\(event.displayTitle) is in its service window now."
            case .overdue:
                return "\(event.displayTitle) is overdue — check the service timeline."
            case .upcoming, .planned:
                return "Next service: \(event.displayTitle) · \(MaintenanceSupport.relativeDueText(for: reminderDate(for: event), now: now))."
            case .completed:
                break
            }
        }

        let coverage = coverageStatusText(plan: plan, now: now)
        return coverage.detail
    }

    // MARK: - Prepared evidence filters

    static let warrantyDocumentCategories: Set<DocumentCategory> = [
        .warranty, .batteryWarranty, .dampReport, .serviceHistory, .purchaseInvoice, .habitationCertificate
    ]

    /// Vehicle identity records captured in Settings — not warranty paperwork for a service event.
    static let vehicleIdentityDocumentCategories: Set<DocumentCategory> = [
        .vinChassisInformation, .crisRegistration
    ]

    static let warrantyMaintenanceCategories: Set<MaintenanceCategory> = [
        .warrantyRepair, .dampInspection, .annualHabitationService
    ]

    /// Paperwork that can be attached to a service event. CRiS VIN Chip and CRiS
    /// registration stay in Settings / Documents unless they are already linked.
    static func linkableDocuments(
        from documents: [DocumentRecord],
        alreadyLinkedIDs: [UUID] = []
    ) -> [DocumentRecord] {
        let linkedIDs = Set(alreadyLinkedIDs)
        return documents.filter { document in
            if linkedIDs.contains(document.id) { return true }
            if vehicleIdentityDocumentCategories.contains(document.category) { return false }
            return document.isWarrantyRelated || warrantyDocumentCategories.contains(document.category)
        }
    }

    static func warrantyDocuments(
        from documents: [DocumentRecord],
        events: [WarrantyEvent]
    ) -> [DocumentRecord] {
        linkableDocuments(
            from: documents,
            alreadyLinkedIDs: events.flatMap(\.linkedDocumentIDs)
        )
    }

    /// Documents on Care/Maintenance that are not yet included in warranty evidence.
    static func unflaggedDocuments(
        from documents: [DocumentRecord],
        events: [WarrantyEvent]
    ) -> [DocumentRecord] {
        let includedIDs = Set(warrantyDocuments(from: documents, events: events).map(\.id))
        return documents.filter { !includedIDs.contains($0.id) }
    }

    static func warrantyFaults(
        from faults: [FaultRecord],
        events: [WarrantyEvent]
    ) -> [FaultRecord] {
        let linkedIDs = Set(events.compactMap(\.linkedFaultID))
        return faults.filter { $0.isWarrantyRelated || linkedIDs.contains($0.id) }
    }

    /// Faults that appear on Care/Maintenance but are not yet included in warranty evidence.
    static func unflaggedFaults(
        from faults: [FaultRecord],
        events: [WarrantyEvent]
    ) -> [FaultRecord] {
        let includedIDs = Set(warrantyFaults(from: faults, events: events).map(\.id))
        return faults.filter { !includedIDs.contains($0.id) }
    }

    static func warrantyRepairs(
        from records: [MaintenanceRecord],
        events: [WarrantyEvent]
    ) -> [MaintenanceRecord] {
        let linkedIDs = Set(events.compactMap(\.linkedMaintenanceID))
        return records.filter {
            warrantyMaintenanceCategories.contains($0.category) || linkedIDs.contains($0.id)
        }
    }

    static func eventEvidenceItems(from events: [WarrantyEvent]) -> [(event: WarrantyEvent, attachment: MaintenanceAttachment)] {
        events.flatMap { event in
            event.attachmentsList.map { (event: event, attachment: $0) }
        }
        .sorted { $0.attachment.createdAt > $1.attachment.createdAt }
    }

    // MARK: - Annual ownership costs

    struct AnnualCostYear: Identifiable, Equatable {
        let year: Int
        let total: Double
        let itemCount: Int

        var id: Int { year }

        var detail: String {
            itemCount == 1 ? "1 cost" : "\(itemCount) costs"
        }
    }

    static func annualCosts(
        events: [WarrantyEvent],
        maintenanceRecords: [MaintenanceRecord],
        faults: [FaultRecord],
        calendar: Calendar = .current
    ) -> [AnnualCostYear] {
        var consumedMaintenanceIDs = Set<UUID>()
        var consumedFaultIDs = Set<UUID>()
        var contributions: [(year: Int, amount: Double)] = []

        let maintenanceByID = Dictionary(uniqueKeysWithValues: maintenanceRecords.map { ($0.id, $0) })
        let faultsByID = Dictionary(uniqueKeysWithValues: faults.map { ($0.id, $0) })

        for event in events {
            let linkedMaintenance = event.linkedMaintenanceID.flatMap { maintenanceByID[$0] }
            let linkedFault = event.linkedFaultID.flatMap { faultsByID[$0] }
            if let linkedMaintenance {
                consumedMaintenanceIDs.insert(linkedMaintenance.id)
            }
            if let linkedFault {
                consumedFaultIDs.insert(linkedFault.id)
                if let linkedFromFault = linkedFault.linkedMaintenanceRecord {
                    consumedMaintenanceIDs.insert(linkedFromFault.id)
                }
            }

            guard let amount = event.actualCost
                ?? linkedMaintenance?.cost
                ?? linkedFault?.repairCost
                ?? event.estimatedCost
            else {
                continue
            }
            let date = event.completedDate ?? event.scheduledDate
            contributions.append((
                year: calendar.component(.year, from: date),
                amount: amount
            ))
        }

        for fault in faults where !consumedFaultIDs.contains(fault.id) {
            let linkedMaintenance = fault.linkedMaintenanceRecord
            if let linkedMaintenance {
                consumedMaintenanceIDs.insert(linkedMaintenance.id)
            }
            guard let amount = fault.actualRepairCost
                ?? linkedMaintenance?.cost
                ?? fault.estimatedRepairCost
            else {
                continue
            }
            let date = fault.resolvedDate ?? fault.discoveredDate
            contributions.append((
                year: calendar.component(.year, from: date),
                amount: amount
            ))
        }

        for record in maintenanceRecords where !consumedMaintenanceIDs.contains(record.id) {
            guard let amount = record.cost else { continue }
            contributions.append((
                year: calendar.component(.year, from: record.serviceDate),
                amount: amount
            ))
        }

        let grouped = Dictionary(grouping: contributions, by: \.year)
        return grouped.keys.sorted().compactMap { year in
            let items = grouped[year] ?? []
            let total = items.reduce(0) { $0 + $1.amount }
            guard total > 0 || !items.isEmpty else { return nil }
            return AnnualCostYear(
                year: year,
                total: total,
                itemCount: items.count
            )
        }
    }

    /// Always returns a cost line for timeline rows: amount when set, otherwise a prompt to add one.
    static func costCaption(for event: WarrantyEvent) -> String {
        guard let amount = event.cost else { return "Add cost" }
        return Formatters.currency(amount)
    }

    static func hasRecordedCost(for event: WarrantyEvent) -> Bool {
        event.cost != nil
    }

    /// Service cost plus any other costs in that year. Nil when nothing has an amount yet.
    static func combinedCost(for event: WarrantyEvent, items: [WarrantyEvent]) -> Double? {
        let amounts = ([event] + items).compactMap(\.cost)
        guard !amounts.isEmpty else { return nil }
        return amounts.reduce(0, +)
    }
}

private extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
}
