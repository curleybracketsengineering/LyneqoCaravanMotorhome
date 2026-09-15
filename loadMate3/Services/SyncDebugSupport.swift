import Combine
import Foundation
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

struct SyncDebugEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

struct SyncDebugSnapshot {
    let accountStatus: CloudSyncAccountStatus
    let lastCheckedAt: Date?
    let lastErrorDescription: String?
    let lastSyncEventSummary: String
    let recentSyncEventLines: [String]
    let lastSuccessfulImportAt: Date?
    let lastSuccessfulExportAt: Date?
    let lastDetailedCloudKitFailure: String?
    let lastMinimalSyncTestResult: String
    let lastAssetCanaryResult: String
    let cloudKitIsolationTestReport: String
    let isRegisteredForRemoteNotifications: Bool
    let pushRegistrationDetail: String
    let cloudKitSchemaDetail: String
    let exportPoisonReport: String
    let deviceName: String
    let bundleID: String
    let appVersion: String
    let buildNumber: String
    let vehicleProfileCount: Int
    let tripCount: Int
    let loadedItemCount: Int
    let libraryItemCount: Int
    let checklistSectionCount: Int
    let checklistItemCount: Int
    let appStateCount: Int
    let activeProfileName: String?
    let syncProbeSequence: Int
    let syncProbeValue: String
    let syncProbeUpdatedAt: Date?
    let syncProbeUpdatedBy: String
}

@MainActor
final class SyncDebugLogger: ObservableObject {
    static let shared = SyncDebugLogger()

    @Published private(set) var entries: [SyncDebugEntry] = []

    private let defaultsKey = "syncDebugEntries"
    private let maxEntries = 80
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode([SyncDebugEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(category: String, message: String) {
        let entry = SyncDebugEntry(category: category, message: message)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        CloudSyncMonitor.shared.clearDiagnostics()
    }

    func copyReport(_ report: String) -> Bool {
        #if canImport(UIKit)
        UIPasteboard.general.string = report
        record(category: "share", message: "Copied sync debug report to clipboard.")
        return true
        #else
        return false
        #endif
    }

    func makeReport(snapshot: SyncDebugSnapshot) -> String {
        let formatter = SyncDebugFormatting.logDateFormatter
        let rows = [
            "Sync Debug Report",
            "Generated: \(formatter.string(from: Date()))",
            "Device: \(snapshot.deviceName)",
            "Bundle ID: \(snapshot.bundleID)",
            "Version: \(snapshot.appVersion) (\(snapshot.buildNumber))",
            "CloudKit container: \(LoadMateModelContainer.cloudKitContainerID)",
            "iCloud status: \(snapshot.accountStatus.settingsTitle)",
            "Last iCloud check: \(SyncDebugFormatting.string(for: snapshot.lastCheckedAt))",
            "Last iCloud error: \(snapshot.lastErrorDescription ?? "None")",
            "Last CloudKit event: \(snapshot.lastSyncEventSummary)",
            "CloudKit event history:",
        ]
        let historyLines = snapshot.recentSyncEventLines.isEmpty
            ? ["  None yet"]
            : snapshot.recentSyncEventLines.map { "  \($0)" }
        let detailedFailure = snapshot.lastDetailedCloudKitFailure?.isEmpty == false
            ? snapshot.lastDetailedCloudKitFailure!
            : "None"
        let afterHistory = [
            "Last Detailed CloudKit Failure",
            detailedFailure,
            "",
            "Last successful import: \(SyncDebugFormatting.string(for: snapshot.lastSuccessfulImportAt))",
            "Last successful export: \(SyncDebugFormatting.string(for: snapshot.lastSuccessfulExportAt))",
            "Minimal sync test: \(snapshot.lastMinimalSyncTestResult)",
            "Tiny asset canary: \(snapshot.lastAssetCanaryResult)",
            "",
            snapshot.cloudKitIsolationTestReport,
            "",
            "Push registered: \(snapshot.isRegisteredForRemoteNotifications ? "Yes" : "No")",
            "Push detail: \(snapshot.pushRegistrationDetail)",
            "CloudKit schema: \(snapshot.cloudKitSchemaDetail)",
            "",
            "Export poison audit",
            snapshot.exportPoisonReport.isEmpty ? "Not run yet" : snapshot.exportPoisonReport,
            "Active profile: \(snapshot.activeProfileName ?? "None")",
            "Counts: profiles=\(snapshot.vehicleProfileCount), trips=\(snapshot.tripCount), loadedItems=\(snapshot.loadedItemCount), libraryItems=\(snapshot.libraryItemCount), checklistSections=\(snapshot.checklistSectionCount), checklistItems=\(snapshot.checklistItemCount), appStates=\(snapshot.appStateCount)",
            "Sync probe sequence: \(snapshot.syncProbeSequence)",
            "Sync probe updated: \(SyncDebugFormatting.string(for: snapshot.syncProbeUpdatedAt))",
            "Sync probe device: \(snapshot.syncProbeUpdatedBy.isEmpty ? "None" : snapshot.syncProbeUpdatedBy)",
            "Sync probe value: \(snapshot.syncProbeValue.isEmpty ? "None" : snapshot.syncProbeValue)",
            "",
            CloudKitModelAudit.report(),
            "",
            SyncDebugTestCatalog.indexText,
            "",
            "Recent log"
        ]

        let logLines = entries.map {
            "[\(formatter.string(from: $0.timestamp))] [\($0.category)] \($0.message)"
        }

        return (rows + historyLines + afterHistory + logLines).joined(separator: "\n")
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Stable numbers for Sync Debug buttons. Never renumber an existing action; add a new unused number instead.
enum SyncDebugTestCatalog {
    static let refreshICloud = 1
    static let checkSchema = 2
    static let writeSyncProbe = 3
    static let minimalSync = 4
    static let compareLocalVsCloudKit = 5
    static let productionHealth = 6
    static let diagnosticAudit = 7
    static let copyDebugReport = 8
    static let logModelAudit = 9
    static let removeDiagnosticRecords = 10
    static let clearLocalLog = 11
    static let isolationAppState = 12
    static let isolationCoreVehicle = 13
    static let isolationChecklist = 14
    static let isolationChecklistGroup = 15
    static let isolationLoadedItem = 16
    static let isolationLibraryItem = 17
    static let tinyAssetCanary = 18
    static let tinyAssetCanaryWithThumbnail = 19
    static let firstSeedSection = 20
    static let watchVehicle = 30
    static let checkWatchedVehicle = 31
    static let documentOnlyCanary = 32
    static let attachmentMetaCanary = 33
    static let sidecarCKAssetCanary = 34

    static func title(_ number: Int, _ name: String) -> String {
        "\(number). \(name)"
    }

    static func seedSectionNumber(_ templateOrder: Int) -> Int {
        firstSeedSection + templateOrder
    }

    static var indexLines: [String] {
        [
            title(refreshICloud, "Refresh iCloud Status"),
            title(checkSchema, "Check CloudKit Schema"),
            title(writeSyncProbe, "Write Sync Probe"),
            title(minimalSync, "Run Minimal Sync Test"),
            title(compareLocalVsCloudKit, "Compare Local vs CloudKit"),
            title(productionHealth, "Run Production Sync Health Check"),
            title(diagnosticAudit, "Run Diagnostic Data Audit"),
            title(copyDebugReport, "Copy Debug Report"),
            title(logModelAudit, "Log Model Audit"),
            title(removeDiagnosticRecords, "Remove Clearly Diagnostic Records"),
            title(clearLocalLog, "Clear Local Log"),
            title(isolationAppState, "Run AppState-Only CloudKit Test (disabled)"),
            title(isolationCoreVehicle, "Run Core Vehicle CloudKit Test (disabled)"),
            title(isolationChecklist, "Run Checklist Model CloudKit Test (disabled)"),
            title(isolationChecklistGroup, "Run ChecklistGroup CloudKit Test (disabled)"),
            title(isolationLoadedItem, "Run LoadedItem CloudKit Test (disabled)"),
            title(isolationLibraryItem, "Run LibraryItem CloudKit Test (disabled)"),
            title(tinyAssetCanary, "Run Tiny Asset Canary"),
            title(tinyAssetCanaryWithThumbnail, "Run Tiny Asset Canary With Thumbnail"),
            title(firstSeedSection, "Add seed section 1 (then 21, 22… by template order)"),
            title(watchVehicle, "Watch vehicle"),
            title(checkWatchedVehicle, "Check whether watched vehicle reappeared"),
            title(documentOnlyCanary, "Run Document Canary (No File)"),
            title(attachmentMetaCanary, "Run Attachment Canary (No Bytes)"),
            title(sidecarCKAssetCanary, "Run Sidecar CKAsset Canary"),
        ]
    }

    static var indexText: String {
        (["Sync Debug test numbers (stable — new actions get a new number)"] + indexLines)
            .joined(separator: "\n")
    }
}

enum SyncDebugSaveHelper {
    @discardableResult
    static func save(_ context: ModelContext, source: String) -> Bool {
        let changeSummary = SyncDebugChangeSummary.describe(context, source: source)
        do {
            try context.save()
            Task { @MainActor in
                SyncDebugLogger.shared.record(
                    category: "save",
                    message: "\(source): \(changeSummary)"
                )
            }
            return true
        } catch {
            Task { @MainActor in
                SyncDebugLogger.shared.record(
                    category: "save",
                    message: "\(source): save failed - \(changeSummary) - \(error.localizedDescription)"
                )
            }
            assertionFailure("SwiftData save failed: \(error.localizedDescription)")
            return false
        }
    }
}

enum SyncDebugChangeSummary {
    static func describe(_ context: ModelContext, source: String) -> String {
        if #available(iOS 18.0, *) {
            let inserted = typeNames(context.insertedModelsArray)
            let deleted = typeNames(context.deletedModelsArray)
            let insertedIDs = Set(context.insertedModelsArray.map { ObjectIdentifier($0) })
            let deletedIDs = Set(context.deletedModelsArray.map { ObjectIdentifier($0) })
            let updated = typeNames(
                context.changedModelsArray.filter {
                    !insertedIDs.contains(ObjectIdentifier($0))
                        && !deletedIDs.contains(ObjectIdentifier($0))
                }
            )
            let summary = describe(inserted: inserted, updated: updated, deleted: deleted)
            if summary != "no model changes" {
                return summary
            }
        }
        return fallbackSummary(source: source)
    }

    static func describe(inserted: [String], updated: [String], deleted: [String]) -> String {
        var order: [String] = []
        var counts: [String: (inserted: Int, updated: Int, deleted: Int)] = [:]

        func add(_ names: [String], as kind: String) {
            for name in names {
                if counts[name] == nil {
                    order.append(name)
                    counts[name] = (0, 0, 0)
                }
                switch kind {
                case "inserted": counts[name]!.inserted += 1
                case "updated": counts[name]!.updated += 1
                default: counts[name]!.deleted += 1
                }
            }
        }

        add(inserted, as: "inserted")
        add(updated, as: "updated")
        add(deleted, as: "deleted")

        guard !order.isEmpty else { return "no model changes" }

        return order.map { name in
            let count = counts[name]!
            var parts: [String] = []
            if count.inserted > 0 { parts.append("\(count.inserted) inserted") }
            if count.updated > 0 { parts.append("\(count.updated) updated") }
            if count.deleted > 0 { parts.append("\(count.deleted) deleted") }
            return "\(name): \(parts.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    static func fallbackSummary(source: String) -> String {
        if source.localizedCaseInsensitiveContains("VehicleProfile") { return "VehicleProfile saved" }
        if source.localizedCaseInsensitiveContains("Trip") { return "Trip saved" }
        if source.localizedCaseInsensitiveContains("Checklist") { return "Checklist saved" }
        if source.localizedCaseInsensitiveContains("Tyre") { return "TyreRecord saved" }
        if source.localizedCaseInsensitiveContains("Accident") { return "AccidentRecord saved" }
        if source.localizedCaseInsensitiveContains("Warranty") { return "WarrantyPlan saved" }
        if source.localizedCaseInsensitiveContains("Maintenance") { return "MaintenanceRecord saved" }
        if source.localizedCaseInsensitiveContains("Document") { return "DocumentRecord saved" }
        if source.localizedCaseInsensitiveContains("Fault") { return "FaultRecord saved" }
        if source.localizedCaseInsensitiveContains("AppState") { return "AppState saved" }
        if source.localizedCaseInsensitiveContains("Load") { return "LoadedItem saved" }
        return "save succeeded"
    }

    private static func typeNames(_ models: [any PersistentModel]) -> [String] {
        models.map { model in
            let raw = String(describing: Swift.type(of: model))
            return raw.split(separator: ".").last.map(String.init) ?? raw
        }
    }
}

enum SyncDebugFormatting {
    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(for date: Date?) -> String {
        guard let date else { return "Never" }
        return displayDateFormatter.string(from: date)
    }

    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }
}
