import Foundation

struct TripStopDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var locationName: String = ""
    var arrivedAt: Date = Date()
    var departedAt: Date = Date()
    var siteCost: Decimal?
    var siteCostText: String = ""
    var notes: String = ""

    static func blank(startDate: Date, endDate: Date) -> TripStopDraft {
        TripStopDraft(arrivedAt: startDate, departedAt: endDate)
    }
}

struct TripLegDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var fromName: String = ""
    var toName: String = ""
    var mileage: Double?
    var mileageText: String = ""
    var travelMinutes: Int?
    var travelTimeText: String = ""
    var travelledOn: Date = Date()
    var notes: String = ""
}

struct TripExpenseDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var category: TripExpenseCategory = .fuel
    var amount: Decimal = 0
    var amountText: String = ""
    var notes: String = ""
}

enum TripRecordValidationIssue: Equatable, Hashable {
    case blankName
    case blankOrigin
    case endBeforeStart
    case blankStopLocation
    case departureBeforeArrival
    case negativeSiteCost
    case unreadableSiteCost
    case blankLegNames
    case negativeMileage
    case unreadableMileage
    case negativeTravelTime
    case unreadableTravelTime
    case unknownExpenseCategory
    case negativeExpense
    case unreadableExpense

    var message: String {
        switch self {
        case .blankName:
            return "Enter a trip name."
        case .blankOrigin:
            return "Enter where the trip starts from."
        case .endBeforeStart:
            return "The end date cannot be before the start date."
        case .blankStopLocation:
            return "Each stay needs a place name."
        case .departureBeforeArrival:
            return "A stay’s departure cannot be before its arrival."
        case .negativeSiteCost:
            return "Site cost cannot be negative."
        case .unreadableSiteCost:
            return "Enter a valid site cost, or leave it blank."
        case .blankLegNames:
            return "Each journey needs a from and to name."
        case .negativeMileage:
            return "Mileage cannot be negative."
        case .unreadableMileage:
            return "Enter a valid mileage, or leave it blank."
        case .negativeTravelTime:
            return "Journey time cannot be negative."
        case .unreadableTravelTime:
            return "Enter journey time as hours:minutes (2:30) or hours (2.5), or leave it blank."
        case .unknownExpenseCategory:
            return "Each cost needs a recognised category."
        case .negativeExpense:
            return "Cost amounts cannot be negative."
        case .unreadableExpense:
            return "Enter a valid cost amount."
        }
    }
}

struct TripRecordDraft: Equatable {
    var existingID: UUID?
    var name: String = ""
    var originName: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var notes: String = ""
    var vehicleProfileID: UUID
    var loadingConfigurationID: UUID?
    var currencyCode: String
    var stops: [TripStopDraft] = []
    var legs: [TripLegDraft] = []
    var expenses: [TripExpenseDraft] = []

    static func blank(vehicleProfileID: UUID, currencyCode: String = TripRecordMoney.defaultCurrencyCode()) -> TripRecordDraft {
        let start = Date()
        return TripRecordDraft(
            startDate: start,
            endDate: start,
            vehicleProfileID: vehicleProfileID,
            currencyCode: currencyCode
        )
    }

    static func from(_ record: TripRecord) -> TripRecordDraft {
        TripRecordDraft(
            existingID: record.id,
            name: record.name,
            originName: record.legsList.first?.fromName ?? "",
            startDate: record.startDate,
            endDate: record.endDate ?? record.startDate,
            notes: record.notes,
            vehicleProfileID: record.vehicleProfileID,
            loadingConfigurationID: record.loadingConfigurationID,
            currencyCode: record.currencyCode.isEmpty ? TripRecordMoney.defaultCurrencyCode() : record.currencyCode,
            stops: record.stopsList.map { stop in
                let cost = stop.siteCostMinorUnits.map {
                    TripRecordMoney.decimal(fromMinorUnits: $0, currencyCode: record.currencyCode)
                }
                return TripStopDraft(
                    id: stop.id,
                    locationName: stop.locationName,
                    arrivedAt: stop.arrivedAt ?? record.startDate,
                    departedAt: stop.departedAt ?? record.endDate ?? record.startDate,
                    siteCost: cost,
                    siteCostText: TripRecordMoney.amountInputString(cost, currencyCode: record.currencyCode),
                    notes: stop.notes
                )
            },
            legs: record.legsList.map { leg in
                TripLegDraft(
                    id: leg.id,
                    fromName: leg.fromName,
                    toName: leg.toName,
                    mileage: leg.mileage,
                    mileageText: mileageInputString(leg.mileage),
                    travelMinutes: leg.travelMinutes,
                    travelTimeText: travelTimeInputString(leg.travelMinutes),
                    travelledOn: leg.travelledOn ?? record.startDate,
                    notes: leg.notes
                )
            },
            expenses: record.expensesList.map { expense in
                let amount = TripRecordMoney.decimal(
                    fromMinorUnits: expense.amountMinorUnits,
                    currencyCode: record.currencyCode
                )
                return TripExpenseDraft(
                    id: expense.id,
                    date: expense.date,
                    category: expense.category,
                    amount: amount,
                    amountText: TripRecordMoney.amountInputString(amount, currencyCode: record.currencyCode),
                    notes: expense.notes
                )
            }
        )
    }

    static func validate(_ draft: TripRecordDraft) -> [TripRecordValidationIssue] {
        var synced = draft
        TripRecordSupport.syncRoutePlaces(in: &synced)
        var issues: [TripRecordValidationIssue] = []
        if synced.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankName)
        }
        if !synced.legs.isEmpty,
           synced.originName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankOrigin)
        }

        let startDay = Calendar.current.startOfDay(for: synced.startDate)
        let endDay = Calendar.current.startOfDay(for: synced.endDate)
        if endDay < startDay {
            issues.append(.endBeforeStart)
        }

        for stop in synced.stops {
            if stop.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.blankStopLocation)
            }
            if stop.departedAt < stop.arrivedAt {
                issues.append(.departureBeforeArrival)
            }
            let trimmedCost = stop.siteCostText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCost.isEmpty {
                continue
            }
            guard let parsed = TripRecordMoney.parseAmount(trimmedCost, currencyCode: synced.currencyCode) else {
                issues.append(.unreadableSiteCost)
                continue
            }
            if parsed < 0 {
                issues.append(.negativeSiteCost)
            }
        }

        for leg in synced.legs {
            let from = leg.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = leg.toName.trimmingCharacters(in: .whitespacesAndNewlines)
            if from.isEmpty || to.isEmpty {
                issues.append(.blankLegNames)
            }
            let trimmedMileage = leg.mileageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedMileage.isEmpty {
                if let parsed = parseMileage(trimmedMileage) {
                    if parsed < 0 {
                        issues.append(.negativeMileage)
                    }
                } else {
                    issues.append(.unreadableMileage)
                }
            }
            let trimmedTime = leg.travelTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTime.isEmpty {
                if let parsed = parseTravelMinutes(trimmedTime) {
                    if parsed < 0 {
                        issues.append(.negativeTravelTime)
                    }
                } else {
                    issues.append(.unreadableTravelTime)
                }
            }
        }

        for expense in synced.expenses {
            if TripExpenseCategory.resolved(from: expense.category.rawValue) == nil {
                issues.append(.unknownExpenseCategory)
            }
            let trimmedAmount = expense.amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAmount.isEmpty {
                if expense.amount < 0 {
                    issues.append(.negativeExpense)
                }
                continue
            }
            guard let parsed = TripRecordMoney.parseAmount(trimmedAmount, currencyCode: synced.currencyCode) else {
                issues.append(.unreadableExpense)
                continue
            }
            if parsed < 0 {
                issues.append(.negativeExpense)
            }
        }

        return uniqueIssues(issues)
    }

    static func preparedForSave(_ draft: TripRecordDraft) -> TripRecordDraft {
        var prepared = draft
        TripRecordSupport.syncRoutePlaces(in: &prepared)
        prepared.name = prepared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.originName = prepared.originName.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.notes = prepared.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        prepared.stops = prepared.stops.map { stop in
            var next = stop
            next.locationName = stop.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            next.notes = stop.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCost = stop.siteCostText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCost.isEmpty {
                next.siteCost = nil
            } else {
                next.siteCost = TripRecordMoney.parseAmount(trimmedCost, currencyCode: prepared.currencyCode)
            }
            return next
        }

        prepared.legs = prepared.legs.map { leg in
            var next = leg
            next.fromName = leg.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
            next.toName = leg.toName.trimmingCharacters(in: .whitespacesAndNewlines)
            next.notes = leg.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMileage = leg.mileageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedMileage.isEmpty {
                next.mileage = nil
            } else {
                next.mileage = parseMileage(trimmedMileage)
            }
            let trimmedTime = leg.travelTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTime.isEmpty {
                next.travelMinutes = nil
            } else {
                next.travelMinutes = parseTravelMinutes(trimmedTime)
            }
            return next
        }

        prepared.expenses = prepared.expenses.map { expense in
            var next = expense
            next.notes = expense.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAmount = expense.amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAmount.isEmpty {
                next.amount = 0
            } else if let parsed = TripRecordMoney.parseAmount(trimmedAmount, currencyCode: draft.currencyCode) {
                next.amount = parsed
            }
            return next
        }

        return prepared
    }

    private static func uniqueIssues(_ issues: [TripRecordValidationIssue]) -> [TripRecordValidationIssue] {
        var seen: Set<TripRecordValidationIssue> = []
        var unique: [TripRecordValidationIssue] = []
        for issue in issues where seen.insert(issue).inserted {
            unique.append(issue)
        }
        return unique
    }

    static func parseMileage(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalised)
    }

    static func mileageInputString(_ mileage: Double?) -> String {
        guard let mileage else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: mileage)) ?? String(format: "%g", mileage)
    }

    static func parseTravelMinutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = normalised.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2,
           let hours = Int(parts[0].trimmingCharacters(in: .whitespaces)),
           let minutes = Int(parts[1].trimmingCharacters(in: .whitespaces)),
           minutes >= 0, minutes < 60 {
            return hours * 60 + minutes
        }
        guard let hours = Double(normalised) else { return nil }
        return Int((hours * 60).rounded())
    }

    static func travelTimeInputString(_ minutes: Int?) -> String {
        guard let minutes else { return "" }
        if minutes == 0 { return "0" }
        let hours = minutes / 60
        let remainder = abs(minutes % 60)
        return String(format: "%d:%02d", hours, remainder)
    }
}
