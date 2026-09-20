import Foundation

enum TripRecordMoney {
    static func defaultCurrencyCode() -> String {
        Locale.current.currency?.identifier ?? "GBP"
    }

    static func fractionDigits(for currencyCode: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        return max(formatter.minimumFractionDigits, 0)
    }

    static func minorUnits(from amount: Decimal, currencyCode: String) -> Int64 {
        let scale = decimalPowerOfTen(fractionDigits(for: currencyCode))
        var scaled = amount * scale
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func decimal(fromMinorUnits units: Int64, currencyCode: String) -> Decimal {
        let scale = decimalPowerOfTen(fractionDigits(for: currencyCode))
        return Decimal(units) / scale
    }

    static func format(_ units: Int64, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        let value = NSDecimalNumber(decimal: decimal(fromMinorUnits: units, currencyCode: currencyCode))
        return formatter.string(from: value) ?? "\(units)"
    }

    static func parseAmount(_ text: String, currencyCode: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        if let number = formatter.number(from: trimmed) {
            return number.decimalValue
        }

        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        if let number = formatter.number(from: trimmed) {
            return number.decimalValue
        }

        let stripped = trimmed
            .replacingOccurrences(of: formatter.currencySymbol ?? "", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doubleValue = Double(stripped) else { return nil }
        return Decimal(doubleValue)
    }

    static func amountInputString(_ amount: Decimal?, currencyCode: String) -> String {
        guard let amount else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits(for: currencyCode)
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private static func decimalPowerOfTen(_ exponent: Int) -> Decimal {
        if exponent <= 0 { return 1 }
        var result: Decimal = 1
        for _ in 0..<exponent {
            result *= 10
        }
        return result
    }
}

struct TripRecordTotals: Equatable {
    var mileage: Double
    var hasMileage: Bool
    var travelMinutes: Int
    var hasTravelTime: Bool
    var stopSiteMinorUnits: Int64
    var hasStopSiteCost: Bool
    var expenseMinorUnits: [TripExpenseCategory: Int64]

    var siteMinorUnits: Int64 {
        stopSiteMinorUnits + (expenseMinorUnits[.site] ?? 0)
    }

    var fuelMinorUnits: Int64 {
        expenseMinorUnits[.fuel] ?? 0
    }

    var otherMinorUnits: Int64 {
        expenseMinorUnits[.other] ?? 0
    }

    var hasSiteCost: Bool {
        hasStopSiteCost || expenseMinorUnits[.site] != nil
    }

    var grandMinorUnits: Int64 {
        stopSiteMinorUnits + expenseMinorUnits.values.reduce(0, +)
    }

    var hasAnyCost: Bool {
        hasStopSiteCost || !expenseMinorUnits.isEmpty
    }

    var summaryRows: [(title: String, minorUnits: Int64)] {
        var rows: [(String, Int64)] = []
        if hasSiteCost {
            rows.append((TripExpenseCategory.site.displayName, siteMinorUnits))
        }
        for category in TripExpenseCategory.allCases where category != .site {
            if let amount = expenseMinorUnits[category] {
                rows.append((category.displayName, amount))
            }
        }
        return rows
    }
}

enum TripRecordSupport {
    static func phase(
        startDate: Date,
        endDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TripRecordPhase {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: startDate)
        if start > today {
            return .upcoming
        }
        if let endDate, calendar.startOfDay(for: endDate) < today {
            return .completed
        }
        return .current
    }

    static func phase(
        for record: TripRecord,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TripRecordPhase {
        phase(startDate: record.startDate, endDate: record.endDate, now: now, calendar: calendar)
    }

    static func groupedForList(
        _ records: [TripRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(TripRecordPhase, [TripRecord])] {
        var current: [TripRecord] = []
        var upcoming: [TripRecord] = []
        var completed: [TripRecord] = []

        for record in records {
            switch phase(for: record, now: now, calendar: calendar) {
            case .current: current.append(record)
            case .upcoming: upcoming.append(record)
            case .completed: completed.append(record)
            }
        }

        current.sort { $0.startDate > $1.startDate }
        upcoming.sort { $0.startDate < $1.startDate }
        completed.sort {
            let lhsEnd = $0.endDate ?? $0.startDate
            let rhsEnd = $1.endDate ?? $1.startDate
            return lhsEnd > rhsEnd
        }

        return [
            (.current, current),
            (.upcoming, upcoming),
            (.completed, completed)
        ].filter { !$0.1.isEmpty }
    }

    static func timelineSorted(
        _ records: [TripRecord]
    ) -> [TripRecord] {
        records.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    struct AnnualCostYear: Identifiable, Equatable {
        let year: Int
        let totalMinorUnits: Int64
        let itemCount: Int
        let currencyCode: String

        var id: Int { year }

        var detail: String {
            itemCount == 1 ? "1 cost" : "\(itemCount) costs"
        }
    }

    static func annualCosts(
        for records: [TripRecord],
        calendar: Calendar = .current
    ) -> [AnnualCostYear] {
        var byYear: [Int: (minorUnits: Int64, count: Int, currencyCode: String)] = [:]
        for record in records {
            let year = calendar.component(.year, from: record.startDate)
            let recordTotals = Self.totals(for: record)
            guard recordTotals.hasAnyCost else { continue }
            let itemCount = recordTotals.summaryRows.count
            var entry = byYear[year] ?? (0, 0, record.currencyCode)
            entry.minorUnits += recordTotals.grandMinorUnits
            entry.count += itemCount
            byYear[year] = entry
        }
        return byYear.keys.sorted(by: >).map { year in
            let entry = byYear[year]!
            return AnnualCostYear(
                year: year,
                totalMinorUnits: entry.minorUnits,
                itemCount: entry.count,
                currencyCode: entry.currencyCode
            )
        }
    }

    static func totals(for record: TripRecord) -> TripRecordTotals {
        let mileages = record.legsList.map(\.mileage)
        let times = record.legsList.map(\.travelMinutes)
        let siteValues = record.stopsList.map(\.siteCostMinorUnits)
        return TripRecordTotals(
            mileage: mileages.compactMap { $0 }.reduce(0, +),
            hasMileage: mileages.contains { $0 != nil },
            travelMinutes: times.compactMap { $0 }.reduce(0, +),
            hasTravelTime: times.contains { $0 != nil },
            stopSiteMinorUnits: siteValues.compactMap { $0 }.reduce(0, +),
            hasStopSiteCost: siteValues.contains { $0 != nil },
            expenseMinorUnits: groupedExpenseMinorUnits(
                record.expensesList.map { ($0.category, $0.amountMinorUnits) }
            )
        )
    }

    static func totals(for draft: TripRecordDraft) -> TripRecordTotals {
        let mileages = draft.legs.map(\.mileage)
        let times = draft.legs.map(\.travelMinutes)
        let siteValues = draft.stops.map(\.siteCost)
        return TripRecordTotals(
            mileage: mileages.compactMap { $0 }.reduce(0, +),
            hasMileage: mileages.contains { $0 != nil },
            travelMinutes: times.compactMap { $0 }.reduce(0, +),
            hasTravelTime: times.contains { $0 != nil },
            stopSiteMinorUnits: siteValues.compactMap { amount in
                amount.map { TripRecordMoney.minorUnits(from: $0, currencyCode: draft.currencyCode) }
            }.reduce(0, +),
            hasStopSiteCost: siteValues.contains { $0 != nil },
            expenseMinorUnits: groupedExpenseMinorUnits(
                draft.expenses.map {
                    ($0.category, TripRecordMoney.minorUnits(from: $0.amount, currencyCode: draft.currencyCode))
                }
            )
        )
    }

    private static func groupedExpenseMinorUnits(
        _ amounts: [(TripExpenseCategory, Int64)]
    ) -> [TripExpenseCategory: Int64] {
        var grouped: [TripExpenseCategory: Int64] = [:]
        for (category, amount) in amounts {
            grouped[category, default: 0] += amount
        }
        return grouped
    }

    static func principalDestination(for record: TripRecord) -> String? {
        let stopName = record.stopsList.first?.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stopName, !stopName.isEmpty { return stopName }
        let toName = record.legsList.first?.toName.trimmingCharacters(in: .whitespacesAndNewlines)
        return toName?.isEmpty == false ? toName : nil
    }

    static func dateRangeText(startDate: Date, endDate: Date?) -> String {
        let start = Formatters.date(startDate)
        guard let endDate else { return start }
        let end = Formatters.date(endDate)
        if start == end { return start }
        return "\(start) – \(end)"
    }

    static func mileageText(_ miles: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        let value = formatter.string(from: NSNumber(value: miles)) ?? String(format: "%g", miles)
        let unit = miles == 1 ? "mile" : "miles"
        return "\(value) \(unit)"
    }

    static func travelTimeText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = abs(minutes % 60)
        if hours == 0 {
            return "\(minutes) min"
        }
        if remainder == 0 {
            return hours == 1 ? "1 hr" : "\(hours) hr"
        }
        return "\(hours) hr \(remainder) min"
    }

    enum RouteCard: Identifiable, Equatable {
        case journey(id: UUID, number: Int)
        case stay(id: UUID, number: Int, place: String)

        var id: String {
            switch self {
            case .journey(let id, _):
                return "journey-\(id.uuidString)"
            case .stay(let id, _, _):
                return "stay-\(id.uuidString)"
            }
        }
    }

    static func routeCards(legIDs: [UUID], stops: [(id: UUID, place: String)]) -> [RouteCard] {
        var cards: [RouteCard] = []
        var journeyNumber = 0
        var stayNumber = 0
        let count = max(legIDs.count, stops.count)
        for index in 0..<count {
            if index < legIDs.count {
                journeyNumber += 1
                cards.append(.journey(id: legIDs[index], number: journeyNumber))
            }
            if index < stops.count {
                stayNumber += 1
                cards.append(.stay(id: stops[index].id, number: stayNumber, place: stops[index].place))
            }
        }
        return cards
    }

    static func routeCards(from draft: TripRecordDraft) -> [RouteCard] {
        routeCards(
            legIDs: draft.legs.map(\.id),
            stops: draft.stops.map { (id: $0.id, place: $0.locationName) }
        )
    }

    static func routeCards(from record: TripRecord) -> [RouteCard] {
        routeCards(
            legIDs: record.legsList.map(\.id),
            stops: record.stopsList.map { (id: $0.id, place: $0.locationName) }
        )
    }

    static func destinationCount(in draft: TripRecordDraft) -> Int {
        min(draft.legs.count, draft.stops.count)
    }

    static func originName(in draft: TripRecordDraft) -> String {
        let origin = draft.originName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !origin.isEmpty { return origin }
        guard let from = draft.legs.first?.fromName.trimmingCharacters(in: .whitespacesAndNewlines),
              !from.isEmpty else {
            return ""
        }
        return from
    }

    static func lastPlace(in draft: TripRecordDraft) -> String {
        if draft.stops.count > draft.legs.count {
            let stay = draft.stops.last?.locationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stay.isEmpty { return stay }
        }
        if let to = draft.legs.last?.toName.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty {
            return to
        }
        if let stay = draft.stops.last?.locationName.trimmingCharacters(in: .whitespacesAndNewlines), !stay.isEmpty {
            return stay
        }
        return originName(in: draft)
    }

    static func syncRoutePlaces(in draft: inout TripRecordDraft) {
        if !draft.legs.isEmpty {
            let origin = draft.originName.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstFrom = draft.legs[0].fromName.trimmingCharacters(in: .whitespacesAndNewlines)
            if firstFrom.isEmpty, !origin.isEmpty {
                draft.legs[0].fromName = draft.originName
            } else if !firstFrom.isEmpty {
                draft.originName = draft.legs[0].fromName
            }
        }

        let pairs = min(draft.legs.count, draft.stops.count)
        for index in 0..<pairs {
            let to = draft.legs[index].toName.trimmingCharacters(in: .whitespacesAndNewlines)
            let stay = draft.stops[index].locationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if to.isEmpty, !stay.isEmpty {
                draft.legs[index].toName = draft.stops[index].locationName
            } else if stay.isEmpty, !to.isEmpty {
                draft.stops[index].locationName = draft.legs[index].toName
            }
        }

        if draft.legs.count > 1 {
            for index in 1..<draft.legs.count {
                let previous: String
                if index - 1 < draft.stops.count {
                    let stay = draft.stops[index - 1].locationName.trimmingCharacters(in: .whitespacesAndNewlines)
                    previous = stay.isEmpty ? draft.legs[index - 1].toName : draft.stops[index - 1].locationName
                } else {
                    previous = draft.legs[index - 1].toName
                }
                if !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.legs[index].fromName = previous
                }
            }
        }
    }

    static func suggestedTravelDate(in draft: TripRecordDraft) -> Date {
        if draft.stops.count >= draft.legs.count, let lastStay = draft.stops.last {
            return lastStay.departedAt
        }
        if let last = draft.legs.last {
            return last.travelledOn
        }
        return draft.startDate
    }

    static func appendStay(to draft: inout TripRecordDraft) {
        let insertAt = draft.stops.count
        let travelDate: Date
        if insertAt > 0 {
            travelDate = draft.stops[insertAt - 1].departedAt
        } else if insertAt < draft.legs.count {
            travelDate = draft.legs[insertAt].travelledOn
        } else {
            travelDate = draft.startDate
        }
        var stay = TripStopDraft.blank(startDate: travelDate, endDate: insertAt == 0 ? draft.endDate : travelDate)
        if insertAt > 0 {
            let previous = draft.stops[insertAt - 1]
            stay.arrivedAt = previous.departedAt
            stay.departedAt = previous.departedAt
        }
        if insertAt < draft.legs.count {
            stay.locationName = draft.legs[insertAt].toName
        }
        draft.stops.append(stay)
        syncRoutePlaces(in: &draft)
    }

    static func appendJourney(to draft: inout TripRecordDraft) {
        let travelDate = suggestedTravelDate(in: draft)
        draft.legs.append(TripLegDraft(fromName: lastPlace(in: draft), travelledOn: travelDate))
        syncRoutePlaces(in: &draft)
    }

    enum RouteMoveSlot: Equatable, Hashable {
        case destination(Int)
        case extraJourney(Int)

        var dragIdentifier: String {
            switch self {
            case .destination(let index):
                return "destination-\(index)"
            case .extraJourney(let index):
                return "extra-\(index)"
            }
        }
    }

    static func moveSlot(forJourneyIndex index: Int, in draft: TripRecordDraft) -> RouteMoveSlot {
        if index < destinationCount(in: draft) {
            return .destination(index)
        }
        return .extraJourney(index)
    }

    static func moveSlot(forStayIndex index: Int, in draft: TripRecordDraft) -> RouteMoveSlot? {
        guard index < destinationCount(in: draft) else { return nil }
        return .destination(index)
    }

    static func moveRoute(in draft: inout TripRecordDraft, from: RouteMoveSlot, to: RouteMoveSlot) {
        switch (from, to) {
        case (.destination(let origin), .destination(let destination)):
            moveDestination(in: &draft, from: origin, to: destination)
        case (.extraJourney(let origin), .extraJourney(let destination)):
            guard origin != destination else { return }
            let toOffset = destination > origin ? destination + 1 : destination
            moveItem(in: &draft.legs, from: origin, toOffset: toOffset)
            syncRoutePlaces(in: &draft)
        default:
            break
        }
    }

    static func moveDestination(in draft: inout TripRecordDraft, from: Int, to destination: Int) {
        let pairs = destinationCount(in: draft)
        guard from >= 0, destination >= 0, from < pairs, destination < pairs, from != destination else { return }
        let toOffset = destination > from ? destination + 1 : destination
        moveItem(in: &draft.legs, from: from, toOffset: toOffset)
        moveItem(in: &draft.stops, from: from, toOffset: toOffset)
        syncRoutePlaces(in: &draft)
    }

    private static func moveItem<T>(in items: inout [T], from: Int, toOffset: Int) {
        guard items.indices.contains(from) else { return }
        let item = items.remove(at: from)
        let insertAt: Int
        if from < toOffset {
            insertAt = min(toOffset - 1, items.count)
        } else {
            insertAt = min(toOffset, items.count)
        }
        items.insert(item, at: max(insertAt, 0))
    }

    static func deleteJourney(in draft: inout TripRecordDraft, id: UUID) {
        guard let index = draft.legs.firstIndex(where: { $0.id == id }) else { return }
        draft.legs.remove(at: index)
        syncRoutePlaces(in: &draft)
    }

    static func deleteStay(in draft: inout TripRecordDraft, id: UUID) {
        guard let index = draft.stops.firstIndex(where: { $0.id == id }) else { return }
        draft.stops.remove(at: index)
        syncRoutePlaces(in: &draft)
    }
}
