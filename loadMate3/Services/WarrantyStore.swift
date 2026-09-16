import Foundation
import SwiftData

enum WarrantyStore {
    @discardableResult
    static func createPlan(for vehicleID: UUID, in context: ModelContext) -> WarrantyPlan {
        let plan = WarrantyPlan(vehicleID: vehicleID)
        context.insert(plan)
        try? context.save()
        return plan
    }

    static func save(
        plan: WarrantyPlan,
        isUnderWarranty: Bool,
        warrantyExpiryDate: Date?,
        manufacturer: String,
        modelYear: Int?,
        purchaseDate: Date,
        purchaseCondition: WarrantyPurchaseCondition,
        ownershipType: WarrantyOwnershipType,
        warrantyType: String,
        durationYears: Int,
        handbookNotes: String,
        templateID: String?,
        motClass: UKMotorhomeMOTClass?,
        in context: ModelContext
    ) {
        plan.isUnderWarranty = isUnderWarranty
        plan.warrantyExpiryDate = warrantyExpiryDate
        plan.manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.modelYear = modelYear
        plan.purchaseDate = purchaseDate
        plan.purchaseCondition = purchaseCondition
        plan.ownershipType = ownershipType
        plan.warrantyType = warrantyType.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.durationYears = max(1, durationYears)
        plan.handbookNotes = handbookNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.templateID = templateID
        plan.motClass = motClass
        plan.updatedAt = Date()
        try? context.save()
    }

    /// Drops manufacturer starter linkage so schedules fall back to custom windows.
    static func clearManufacturerTemplate(for vehicleID: UUID, in context: ModelContext) {
        let descriptor = FetchDescriptor<WarrantyPlan>(
            predicate: #Predicate { $0.vehicleID == vehicleID }
        )
        guard let plans = try? context.fetch(descriptor) else { return }
        for plan in plans where plan.templateID != nil {
            plan.templateID = nil
            plan.updatedAt = Date()
        }
        try? context.save()
    }

    @discardableResult
    static func createEvent(for plan: WarrantyPlan, in context: ModelContext) -> WarrantyEvent {
        let event = WarrantyEvent(vehicleID: plan.vehicleID)
        event.plan = plan
        let nextOrder = (plan.events ?? []).map(\.sortOrder).max().map { $0 + 1 } ?? 0
        event.sortOrder = nextOrder
        context.insert(event)
        try? context.save()
        return event
    }

    static func save(
        event: WarrantyEvent,
        yearNumber: Int,
        scheduledDate: Date,
        daysBefore: Int,
        daysAfter: Int,
        serviceType: WarrantyServiceType,
        requirementDescription: String,
        sortOrder: Int,
        isManual: Bool,
        completedDate: Date?,
        linkedDocumentIDs: [UUID],
        linkedMaintenanceID: UUID?,
        linkedFaultID: UUID?,
        parentEventID: UUID? = nil,
        cost: Double? = nil,
        in context: ModelContext
    ) {
        event.yearNumber = yearNumber
        event.scheduledDate = scheduledDate
        event.daysBefore = max(0, daysBefore)
        event.daysAfter = max(0, daysAfter)
        event.serviceType = serviceType
        event.requirementDescription = requirementDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        event.sortOrder = sortOrder
        event.isManual = isManual
        event.completedDate = completedDate
        event.linkedDocumentIDs = linkedDocumentIDs
        event.linkedMaintenanceID = linkedMaintenanceID
        event.linkedFaultID = linkedFaultID
        event.parentEventID = parentEventID
        event.actualCost = cost
        event.estimatedCost = nil
        event.updatedAt = Date()
        try? context.save()
    }

    /// Creates additional yearly copies of a service event from its due date through the plan horizon.
    /// Skips dates that already have a matching event (same type, requirement, and calendar day).
    @discardableResult
    static func ensureYearlyRepeats(
        for plan: WarrantyPlan,
        matching event: WarrantyEvent,
        in context: ModelContext
    ) -> [WarrantyEvent] {
        let start = event.scheduledDate
        let end = WarrantySupport.yearlyRepeatEndDate(for: plan, startingFrom: start)
        let dates = WarrantySupport.yearlyOccurrenceDates(from: start, through: end)
        let requirement = event.requirementDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        var occupiedDays = Set(
            plan.eventsList
                .filter {
                    $0.serviceType == event.serviceType
                        && $0.requirementDescription.trimmingCharacters(in: .whitespacesAndNewlines) == requirement
                }
                .map { calendar.startOfDay(for: $0.scheduledDate) }
        )
        var created: [WarrantyEvent] = []
        var nextOrder = (plan.events ?? []).map(\.sortOrder).max().map { $0 + 1 } ?? 0

        for date in dates {
            let day = calendar.startOfDay(for: date)
            guard !occupiedDays.contains(day) else { continue }

            let copy = WarrantyEvent(vehicleID: plan.vehicleID)
            copy.plan = plan
            copy.sortOrder = nextOrder
            nextOrder += 1
            context.insert(copy)

            let yearNumber = WarrantySupport.yearNumber(for: day, purchaseDate: plan.purchaseDate)
            save(
                event: copy,
                yearNumber: yearNumber,
                scheduledDate: day,
                daysBefore: event.daysBefore,
                daysAfter: event.daysAfter,
                serviceType: event.serviceType,
                requirementDescription: requirement,
                sortOrder: yearNumber > 0 ? yearNumber * 10 : copy.sortOrder,
                isManual: true,
                completedDate: nil,
                linkedDocumentIDs: [],
                linkedMaintenanceID: nil,
                linkedFaultID: nil,
                cost: nil,
                in: context
            )
            occupiedDays.insert(day)
            created.append(copy)
        }

        return created
    }

    static func delete(event: WarrantyEvent, in context: ModelContext) {
        var doomed = [event]
        if let plan = event.plan {
            doomed.append(contentsOf: plan.costItems(for: event))
        }
        promoteEventAttachmentsToDocuments(events: doomed, in: context)
        if let plan = event.plan {
            for item in plan.costItems(for: event) {
                remove(event: item, in: context)
            }
        }
        remove(event: event, in: context)
        try? context.save()
    }

    private static func remove(event: WarrantyEvent, in context: ModelContext) {
        for attachment in event.attachmentsList {
            MaintenanceAttachmentStore.delete(attachment, in: context)
        }
        context.delete(event)
    }

    static func delete(plan: WarrantyPlan, in context: ModelContext) {
        promoteEventAttachmentsToDocuments(events: plan.eventsList, in: context)
        for event in plan.eventsList {
            remove(event: event, in: context)
        }
        context.delete(plan)
        try? context.save()
    }

    static func link(document: DocumentRecord, to event: WarrantyEvent, in context: ModelContext) {
        var ids = event.linkedDocumentIDs
        if !ids.contains(document.id) {
            ids.append(document.id)
            event.linkedDocumentIDs = ids
            event.updatedAt = Date()
        }
        document.isWarrantyRelated = true
        document.updatedAt = Date()
        try? context.save()
    }

    static func unlink(documentID: UUID, from event: WarrantyEvent, in context: ModelContext) {
        let remaining = event.linkedDocumentIDs.filter { $0 != documentID }
        guard remaining.count != event.linkedDocumentIDs.count else { return }
        event.linkedDocumentIDs = remaining
        event.updatedAt = Date()
        try? context.save()
    }

    static func setLinkedEvents(
        for document: DocumentRecord,
        eventIDs: Set<UUID>,
        among events: [WarrantyEvent],
        in context: ModelContext
    ) {
        for event in events {
            let shouldLink = eventIDs.contains(event.id)
            let isLinked = event.linkedDocumentIDs.contains(document.id)
            if shouldLink, !isLinked {
                link(document: document, to: event, in: context)
            } else if !shouldLink, isLinked {
                unlink(documentID: document.id, from: event, in: context)
            }
        }

        let stillLinked = events.contains { $0.linkedDocumentIDs.contains(document.id) }
        if stillLinked {
            document.isWarrantyRelated = true
        } else if !WarrantySupport.warrantyDocumentCategories.contains(document.category) {
            document.isWarrantyRelated = false
        }
        document.updatedAt = Date()
        try? context.save()
    }

    /// Files added on a service event are stored as a Documents record so they also appear in Documents.
    static func attachDrafts(
        _ drafts: [MaintenanceAttachmentDraft],
        to event: WarrantyEvent,
        in context: ModelContext
    ) {
        guard !drafts.isEmpty else { return }
        let document = linkedOrCreateDocument(
            for: event,
            preferredTitle: WarrantySupport.documentTitle(for: event),
            in: context
        )
        MaintenanceAttachmentStore.save(drafts: drafts, to: .document(document), in: context)
    }

    /// Moves leftover event-only files onto linked Care documents.
    @discardableResult
    static func promoteEventAttachmentsToDocuments(
        events: [WarrantyEvent],
        in context: ModelContext
    ) -> Int {
        var moved = 0
        for event in events {
            let attachments = event.attachmentsList
            guard !attachments.isEmpty else { continue }
            let document = linkedOrCreateDocument(
                for: event,
                preferredTitle: WarrantySupport.documentTitle(for: event),
                in: context
            )
            for attachment in attachments {
                attachment.warrantyEvent = nil
                attachment.documentRecord = document
                moved += 1
            }
            event.updatedAt = Date()
        }
        if moved > 0 {
            try? context.save()
        }
        return moved
    }

    private static func linkedOrCreateDocument(
        for event: WarrantyEvent,
        preferredTitle: String,
        in context: ModelContext
    ) -> DocumentRecord {
        let category = WarrantySupport.documentCategory(for: event.serviceType)
        let linkedIDs = Set(event.linkedDocumentIDs)
        if !linkedIDs.isEmpty {
            let documents = (try? context.fetch(FetchDescriptor<DocumentRecord>())) ?? []
            if let existing = documents.first(where: {
                linkedIDs.contains($0.id) && $0.vehicleID == event.vehicleID
            }) ?? documents.first(where: { linkedIDs.contains($0.id) }) {
                return existing
            }
        }

        let record = DocumentStore.createRecord(for: event.vehicleID, in: context)
        DocumentStore.save(
            record: record,
            title: preferredTitle,
            category: category,
            dateAdded: event.completedDate ?? event.scheduledDate,
            expiryDate: nil,
            reminderDate: nil,
            notes: "",
            isWarrantyRelated: true,
            in: context
        )
        link(document: record, to: event, in: context)
        return record
    }

    /// Keeps one service plan per vehicle after iCloud duplicates. Prefers completed work and photos.
    @MainActor
    @discardableResult
    static func mergeDuplicatePlans(in context: ModelContext) -> Bool {
        let plans = (try? context.fetch(FetchDescriptor<WarrantyPlan>())) ?? []
        let groups = Dictionary(grouping: plans, by: \.vehicleID)
        var didChange = false

        for (_, cluster) in groups where cluster.count > 1 {
            let ranked = cluster.sorted {
                WarrantySupport.retentionScore(for: $0) > WarrantySupport.retentionScore(for: $1)
            }
            guard let winner = ranked.first else { continue }
            let winnerHasCompleted = winner.eventsList.contains { $0.completedDate != nil }

            for loser in ranked.dropFirst() {
                let loserHasCompleted = loser.eventsList.contains { $0.completedDate != nil }
                if winnerHasCompleted && !loserHasCompleted {
                    for event in loser.eventsList {
                        remove(event: event, in: context)
                    }
                } else {
                    for event in loser.eventsList {
                        event.plan = winner
                        event.vehicleID = winner.vehicleID
                    }
                }
                context.delete(loser)
                didChange = true
            }
        }

        if didChange {
            try? context.save()
            SyncDebugLogger.shared.record(
                category: "startup",
                message: "[migration] merged duplicate WarrantyPlan records for the same vehicle"
            )
        }
        return didChange
    }

    static func generateAnnualEvents(
        plan: WarrantyPlan,
        in context: ModelContext,
        kind: VehicleKind? = nil,
        ukMarket: Bool? = nil,
        replaceAutoGenerated: Bool = false
    ) {
        let profile = vehicleProfile(for: plan.vehicleID, in: context)
        defer {
            if let profile {
                syncInsuranceRenewalEvents(for: profile, in: context)
            }
        }

        if replaceAutoGenerated {
            let toRemove = plan.eventsList.filter { !$0.isManual && $0.serviceType != .insuranceRenewal }
            for event in toRemove {
                delete(event: event, in: context)
            }
        }

        let existingAuto = plan.eventsList.filter { !$0.isManual && $0.serviceType != .insuranceRenewal }
        let existingHabitationYears = Set(
            existingAuto.filter { !$0.serviceType.isStatutoryInspection }.map(\.yearNumber)
        )
        let existingStatutoryYears = Set(
            existingAuto.filter { $0.serviceType.isStatutoryInspection }.map(\.yearNumber)
        )
        let calendar = Calendar.current
        let resolvedKind = kind ?? profile?.kind ?? .caravan
        let resolvedUKMarket = ukMarket ?? profile?.warrantyUKMarket ?? true
        let template = WarrantySupport.patternOrCustom(id: plan.templateID, kind: resolvedKind)

        for year in 1...plan.durationYears {
            guard !existingHabitationYears.contains(year) else { continue }
            guard let scheduledDate = calendar.date(byAdding: .year, value: year, to: plan.purchaseDate) else {
                continue
            }

            let event = createEvent(for: plan, in: context)
            let window = template.window(forYear: year)
            let serviceType = template.serviceType(forYear: year)
            save(
                event: event,
                yearNumber: year,
                scheduledDate: scheduledDate,
                daysBefore: window.daysBefore,
                daysAfter: window.daysAfter,
                serviceType: serviceType,
                requirementDescription: template.requirement(forYear: year),
                sortOrder: year * 10,
                isManual: false,
                completedDate: nil,
                linkedDocumentIDs: [],
                linkedMaintenanceID: nil,
                linkedFaultID: nil,
                in: context
            )
        }

        guard resolvedKind == .motorhome else { return }

        if resolvedUKMarket {
            let motClass = plan.motClass
                ?? profile.map(WarrantySupport.suggestedMOTClass(for:))
                ?? .class4
            plan.motClass = motClass

            let firstYear = motClass.firstTestYear
            guard plan.durationYears >= firstYear else { return }

            for year in firstYear...plan.durationYears {
                guard !existingStatutoryYears.contains(year) else { continue }
                guard let scheduledDate = calendar.date(byAdding: .year, value: year, to: plan.purchaseDate) else {
                    continue
                }

                let event = createEvent(for: plan, in: context)
                save(
                    event: event,
                    yearNumber: year,
                    scheduledDate: scheduledDate,
                    daysBefore: motClass.daysBefore,
                    daysAfter: motClass.daysAfter,
                    serviceType: .mot,
                    requirementDescription: motClass.requirementDescription,
                    sortOrder: year * 10 + 1,
                    isManual: false,
                    completedDate: nil,
                    linkedDocumentIDs: [],
                    linkedMaintenanceID: nil,
                    linkedFaultID: nil,
                    in: context
                )
            }
            return
        }

        let firstYear = WarrantySupport.motorhomeVehicleInspectionFirstYear
        guard plan.durationYears >= firstYear else { return }

        for year in firstYear...plan.durationYears {
            guard !existingStatutoryYears.contains(year) else { continue }
            guard let scheduledDate = calendar.date(byAdding: .year, value: year, to: plan.purchaseDate) else {
                continue
            }

            let event = createEvent(for: plan, in: context)
            save(
                event: event,
                yearNumber: year,
                scheduledDate: scheduledDate,
                daysBefore: WarrantySupport.motorhomeVehicleInspectionDaysBefore,
                daysAfter: WarrantySupport.motorhomeVehicleInspectionDaysAfter,
                serviceType: .vehicleInspection,
                requirementDescription: WarrantyServiceType.vehicleInspection.defaultRequirementDescription,
                sortOrder: year * 10 + 1,
                isManual: false,
                completedDate: nil,
                linkedDocumentIDs: [],
                linkedMaintenanceID: nil,
                linkedFaultID: nil,
                in: context
            )
        }
    }

    /// Creates or refreshes yearly insurance-check actions from the vehicle's insurance start date.
    /// Incomplete insurance events are replaced when the start date changes; completed ones are kept.
    /// Creates a service plan if the timeline is enabled and none exists yet.
    @discardableResult
    static func syncInsuranceRenewalEvents(
        for profile: VehicleProfile,
        in context: ModelContext,
        now: Date = Date()
    ) -> [WarrantyEvent] {
        guard profile.warrantyAvailable else { return [] }

        let vehicleID = profile.id
        let planDescriptor = FetchDescriptor<WarrantyPlan>(
            predicate: #Predicate { $0.vehicleID == vehicleID }
        )
        let existingPlans = (try? context.fetch(planDescriptor)) ?? []
        let plan: WarrantyPlan? = {
            if let existing = existingPlans.first { return existing }
            guard profile.insuranceStartDate != nil else { return nil }
            return createPlan(for: vehicleID, in: context)
        }()
        guard let plan else { return [] }

        let requirement = WarrantySupport.insuranceRenewalRequirement(for: profile.kind)
        let calendar = Calendar.current
        let existingInsurance = plan.eventsList.filter { $0.serviceType == .insuranceRenewal }

        guard let start = profile.insuranceStartDate else {
            for event in existingInsurance where event.completedDate == nil {
                delete(event: event, in: context)
            }
            plan.updatedAt = Date()
            try? context.save()
            return []
        }

        let targetDays = Set(
            WarrantySupport.insuranceRenewalDates(from: start, now: now).map { calendar.startOfDay(for: $0) }
        )

        // Drop open insurance rows that no longer match the anniversary schedule.
        for event in existingInsurance where event.completedDate == nil {
            let day = calendar.startOfDay(for: event.scheduledDate)
            let requirementMatches = event.requirementDescription.trimmingCharacters(in: .whitespacesAndNewlines) == requirement
            if !targetDays.contains(day) || !requirementMatches {
                delete(event: event, in: context)
            }
        }

        let occupiedDays = Set(
            plan.eventsList
                .filter { $0.serviceType == .insuranceRenewal }
                .map { calendar.startOfDay(for: $0.scheduledDate) }
        )

        var created: [WarrantyEvent] = []
        for day in targetDays.sorted() where !occupiedDays.contains(day) {
            let event = createEvent(for: plan, in: context)
            let yearNumber = WarrantySupport.yearNumber(for: day, purchaseDate: plan.purchaseDate)
            save(
                event: event,
                yearNumber: yearNumber,
                scheduledDate: day,
                daysBefore: WarrantySupport.insuranceRenewalDaysBefore,
                daysAfter: WarrantySupport.insuranceRenewalDaysAfter,
                serviceType: .insuranceRenewal,
                requirementDescription: requirement,
                sortOrder: yearNumber > 0 ? yearNumber * 10 + 2 : event.sortOrder,
                isManual: false,
                completedDate: nil,
                linkedDocumentIDs: [],
                linkedMaintenanceID: nil,
                linkedFaultID: nil,
                in: context
            )
            created.append(event)
        }

        // Keep wording fresh on existing open insurance rows.
        for event in plan.eventsList where event.serviceType == .insuranceRenewal && event.completedDate == nil {
            if event.requirementDescription != requirement {
                event.requirementDescription = requirement
                event.updatedAt = Date()
            }
        }

        plan.updatedAt = Date()
        try? context.save()
        return created
    }

    private static func vehicleProfile(for vehicleID: UUID, in context: ModelContext) -> VehicleProfile? {
        let descriptor = FetchDescriptor<VehicleProfile>(
            predicate: #Predicate { $0.id == vehicleID }
        )
        return try? context.fetch(descriptor).first
    }
}
