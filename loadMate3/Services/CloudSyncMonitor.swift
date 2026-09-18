import CloudKit
import Combine
import CoreData
import Foundation
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

enum MinimalSyncTestStatus: String, Equatable {
  case notRun = "Not run"
  case running = "Running"
  case localSaveSucceeded = "Local save succeeded"
  case localSaveFailed = "Local save failed"
  case waitingForCloudKit = "Waiting for CloudKit"
  case exportSucceeded = "CloudKit export succeeded"
  case exportFailed = "CloudKit export failed"
  case timedOut = "Timed out"
}

enum CloudSyncAccountStatus: Equatable {
  case available
  case noAccount
  case restricted
  case couldNotDetermine
  case temporarilyUnavailable

  var settingsTitle: String {
    switch self {
    case .available: return "iCloud sync is on"
    case .noAccount: return "Sign in to iCloud"
    case .restricted: return "iCloud access restricted"
    case .couldNotDetermine: return "Checking iCloud…"
    case .temporarilyUnavailable: return "iCloud temporarily unavailable"
    }
  }

  var settingsDetail: String {
    switch self {
    case .available:
      return "Your vehicles, loading configurations, load lists, checklists, documents, and photos stay up to date across your iPhone and iPad signed into the same Apple ID."
    case .noAccount:
      return "Open Settings → Apple Account and sign in to iCloud to sync Lyneqo Caravan & Motorhome between your devices."
    case .restricted:
      return "This device cannot use iCloud right now. Check Screen Time or device management restrictions."
    case .couldNotDetermine:
      return "Lyneqo Caravan & Motorhome will keep trying to reach iCloud."
    case .temporarilyUnavailable:
      return "iCloud is not reachable at the moment. Your data is saved on this device and will sync when iCloud is back."
    }
  }

  var systemImage: String {
    switch self {
    case .available: return "icloud.fill"
    case .noAccount: return "icloud.slash"
    case .restricted: return "lock.icloud"
    case .couldNotDetermine: return "icloud"
    case .temporarilyUnavailable: return "icloud.slash"
    }
  }
}

enum CloudSyncEventKind: String, Codable, Equatable {
  case setup
  case importFromCloud = "import"
  case exportToCloud = "export"
  case unknown

  var displayName: String {
    switch self {
    case .setup: return "Setup"
    case .importFromCloud: return "Import"
    case .exportToCloud: return "Export"
    case .unknown: return "Unknown"
    }
  }
}

struct CloudSyncEventSummary: Equatable {
  var kind: CloudSyncEventKind
  var succeeded: Bool
  var finishedAt: Date
  var errorDescription: String?
}

enum CloudSyncEventPhase: String, Codable, Equatable {
  case started
  case succeeded
  case failed
  case partialFailure

  var displayName: String {
    switch self {
    case .started: return "started"
    case .succeeded: return "succeeded"
    case .failed: return "failed"
    case .partialFailure: return "partial failure"
    }
  }
}

struct CloudSyncHistoryEntry: Identifiable, Equatable, Codable {
  let id: UUID
  let timestamp: Date
  let kind: CloudSyncEventKind
  let phase: CloudSyncEventPhase
  let context: String

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: CloudSyncEventKind,
    phase: CloudSyncEventPhase,
    context: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.phase = phase
    self.context = context
  }

  var displayLine: String {
    "\(SyncDebugFormatting.logDateFormatter.string(from: timestamp))  \(context)"
  }

  static func make(
    kind: CloudSyncEventKind,
    started: Bool,
    succeeded: Bool,
    error: Error?,
    timestamp: Date = Date()
  ) -> CloudSyncHistoryEntry {
    let phase: CloudSyncEventPhase
    if started {
      phase = .started
    } else if succeeded {
      phase = .succeeded
    } else if let error, CloudSyncErrorFormatting.isPartialFailure(error) {
      phase = .partialFailure
    } else {
      phase = .failed
    }

    let models = error.map { CloudSyncErrorFormatting.involvedModels(in: $0) } ?? []
    return CloudSyncHistoryEntry(
      timestamp: timestamp,
      kind: kind,
      phase: phase,
      context: contextLabel(kind: kind, phase: phase, models: models)
    )
  }

  static func contextLabel(
    kind: CloudSyncEventKind,
    phase: CloudSyncEventPhase,
    models: [String] = []
  ) -> String {
    var line = "\(kind.displayName.uppercased()) \(phase.displayName)"
    if !models.isEmpty {
      line += " — \(models.joined(separator: ", "))"
    }
    return line
  }
}

enum CloudSyncEventHistory {
  static let maxEntries = 20

  static func prepending(
    _ entry: CloudSyncHistoryEntry,
    onto events: [CloudSyncHistoryEntry]
  ) -> [CloudSyncHistoryEntry] {
    Array(([entry] + events).prefix(maxEntries))
  }
}

@MainActor
final class CloudSyncMonitor: ObservableObject {
  static let shared = CloudSyncMonitor()

  @Published private(set) var accountStatus: CloudSyncAccountStatus = .couldNotDetermine
  @Published private(set) var lastCheckedAt: Date?
  @Published private(set) var lastErrorDescription: String?
  @Published private(set) var lastSyncEvent: CloudSyncEventSummary?
  @Published private(set) var recentSyncEvents: [CloudSyncHistoryEntry] = []
  @Published private(set) var lastSuccessfulImportAt: Date?
  @Published private(set) var lastSuccessfulExportAt: Date?
  @Published private(set) var isObservingSyncEvents = false
  @Published private(set) var isRegisteredForRemoteNotifications = false
  @Published private(set) var pushRegistrationDetail = "Waiting for APNs registration…"
  @Published private(set) var cloudKitSchemaDetail = "Not checked yet"
  @Published private(set) var lastExportPoisonReport: String?
  @Published private(set) var lastDetailedCloudKitFailure: String?
  @Published private(set) var pendingMinimalSyncTestID: String?
  @Published private(set) var lastMinimalSyncTestID: String?
  @Published private(set) var minimalSyncTestStatus: MinimalSyncTestStatus = .notRun
  @Published private(set) var lastMinimalSyncTestResult = MinimalSyncTestStatus.notRun.rawValue
  private(set) var seenCloudKitStoreIdentifiers: Set<String> = []

  private var accountObserver: NSObjectProtocol?
  private var syncEventObserver: NSObjectProtocol?
  private var didStart = false
  private let historyDefaultsKey = "cloudSyncEventHistory"
  private let lastDetailedFailureDefaultsKey = "cloudSyncLastDetailedFailure"
  private let lastExportPoisonDefaultsKey = "cloudSyncLastExportPoisonReport"
  private let minimalSyncStatusDefaultsKey = "cloudSyncMinimalSyncTestStatus"
  private let minimalSyncIDDefaultsKey = "cloudSyncMinimalSyncTestID"
  private let historyEncoder = JSONEncoder()
  private let historyDecoder = JSONDecoder()
  private weak var modelContext: ModelContext?
  private var inFlightStarts: [CloudSyncEventKind: (date: Date, counts: SyncDebugEntityCounts?, profileIDs: Set<UUID>)] = [:]
  private var isolationProductionStoreIDs: Set<String>?
  private var minimalSyncTimeoutTask: Task<Void, Never>?

  private init() {
    start()
  }

  deinit {
    if let accountObserver {
      NotificationCenter.default.removeObserver(accountObserver)
    }
    if let syncEventObserver {
      NotificationCenter.default.removeObserver(syncEventObserver)
    }
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    historyDecoder.dateDecodingStrategy = .iso8601
    historyEncoder.dateEncodingStrategy = .iso8601
    loadEventHistory()
    loadLastDetailedFailure()
    loadLastExportPoisonReport()
    loadMinimalSyncTestStatus()
    observeAccountChanges()
    observeSyncEvents()
    refreshPushRegistrationStatus()
    Task { await refresh() }
  }

  func waitForNextExport(timeout: TimeInterval = 90) async -> Bool {
    let baseline = lastSuccessfulExportAt ?? .distantPast
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let last = lastSuccessfulExportAt, last > baseline { return true }
      if let event = lastSyncEvent,
         event.kind == .exportToCloud,
         event.finishedAt > baseline,
         !event.succeeded {
        return false
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return false
  }

  func attachModelContext(_ context: ModelContext) {
    modelContext = context
  }

  func currentEntityCounts() -> SyncDebugEntityCounts? {
    guard let modelContext else { return nil }
    return SyncDebugEntityCounts.fetch(from: modelContext)
  }

  func currentProfileIDs() -> Set<UUID> {
    guard let modelContext else { return [] }
    let profiles = (try? modelContext.fetch(FetchDescriptor<VehicleProfile>())) ?? []
    return Set(profiles.map(\.id))
  }

  func currentEntityCountsLine() -> String? {
    currentEntityCounts()?.logLine
  }

  func beginMinimalSyncTest(identifier: String) {
    minimalSyncTimeoutTask?.cancel()
    pendingMinimalSyncTestID = identifier
    lastMinimalSyncTestID = identifier
    setMinimalSyncTestStatus(.running)
  }

  func noteMinimalSyncLocalSave(succeeded: Bool) {
    if succeeded {
      setMinimalSyncTestStatus(.localSaveSucceeded)
      setMinimalSyncTestStatus(.waitingForCloudKit)
      startMinimalSyncTimeout()
    } else {
      setMinimalSyncTestStatus(.localSaveFailed)
      pendingMinimalSyncTestID = nil
      minimalSyncTimeoutTask?.cancel()
      minimalSyncTimeoutTask = nil
    }
  }

  func beginIgnoringNonProductionCloudKitStores(productionStoreIDs: Set<String>) {
    isolationProductionStoreIDs = productionStoreIDs
  }

  func endIgnoringNonProductionCloudKitStores() {
    isolationProductionStoreIDs = nil
  }

  func markMinimalSyncTestStarted(identifier: String) {
    beginMinimalSyncTest(identifier: identifier)
  }

  func clearEventHistory() {
    recentSyncEvents = []
    UserDefaults.standard.removeObject(forKey: historyDefaultsKey)
  }

  func clearDiagnostics() {
    clearEventHistory()
    lastDetailedCloudKitFailure = nil
    lastExportPoisonReport = nil
    UserDefaults.standard.removeObject(forKey: lastDetailedFailureDefaultsKey)
    UserDefaults.standard.removeObject(forKey: lastExportPoisonDefaultsKey)
  }

  func refresh() async {
    refreshPushRegistrationStatus()
    do {
      let status = try await CKContainer(identifier: LoadMateModelContainer.cloudKitContainerID)
        .accountStatus()
      accountStatus = map(status)
      lastErrorDescription = nil
      lastCheckedAt = Date()
      SyncDebugLogger.shared.record(
        category: "icloud",
        message: "Account status refreshed: \(accountStatus.settingsTitle)."
      )
    } catch {
      accountStatus = .couldNotDetermine
      lastErrorDescription = CloudSyncErrorFormatting.description(for: error)
      lastCheckedAt = Date()
      SyncDebugLogger.shared.record(
        category: "icloud",
        message: "Account status refresh failed:\n\(CloudSyncErrorFormatting.dump(for: error))"
      )
    }
  }

  func refreshPushRegistrationStatus() {
    #if canImport(UIKit)
    let registered = UIApplication.shared.isRegisteredForRemoteNotifications
    isRegisteredForRemoteNotifications = registered
    if registered, pushRegistrationDetail.hasPrefix("Waiting") {
      pushRegistrationDetail = "Registered for remote notifications."
    } else if !registered, pushRegistrationDetail.hasPrefix("Waiting") {
      pushRegistrationDetail =
        "Not registered yet (on Simulator this is often inconclusive; on a real device check the push entitlement)."
    }
    #else
    isRegisteredForRemoteNotifications = false
    pushRegistrationDetail = "UIKit unavailable."
    #endif
  }

  func handlePushRegistrationSuccess(deviceTokenByteCount: Int) {
    isRegisteredForRemoteNotifications = true
    pushRegistrationDetail = "Registered for remote notifications (\(deviceTokenByteCount) byte token)."
    SyncDebugLogger.shared.record(
      category: "push",
      message: "Registered for remote notifications (\(deviceTokenByteCount) byte token)."
    )
  }

  func handlePushRegistrationFailure(_ error: Error) {
    isRegisteredForRemoteNotifications = false
    pushRegistrationDetail = "Push registration failed: \(error.localizedDescription)"
    lastErrorDescription = pushRegistrationDetail
    SyncDebugLogger.shared.record(
      category: "push",
      message: "Push registration failed: \(error.localizedDescription)"
    )
  }

  /// Asks CloudKit whether the Core Data zone and `CD_AppState` record type exist in this build's environment.
  func probeCloudKitSchema() async {
    let container = CKContainer(identifier: LoadMateModelContainer.cloudKitContainerID)
    let database = container.privateCloudDatabase
    let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")

    SyncDebugLogger.shared.record(category: "schema", message: "Probing CloudKit schema…")

    do {
      let zones = try await database.allRecordZones()
      let hasCoreDataZone = zones.contains { $0.zoneID.zoneName == zoneID.zoneName }

      guard hasCoreDataZone else {
        cloudKitSchemaDetail =
          "No Core Data CloudKit zone yet. Schema may be fine but nothing has mirrored — or this environment is empty."
        SyncDebugLogger.shared.record(category: "schema", message: cloudKitSchemaDetail)
        return
      }

      let query = CKQuery(recordType: "CD_AppState", predicate: NSPredicate(value: true))
      let (matchResults, _) = try await database.records(matching: query, inZoneWith: zoneID)
      let recordCount = matchResults.reduce(into: 0) { count, pair in
        if case .success = pair.1 { count += 1 }
      }
      var probeLines = [
        "CloudKit connectivity/schema probe:",
        "CD_AppState reachable (\(recordCount) record\(recordCount == 1 ? "" : "s"))",
      ]
      let extraTypes = [
        "CD_VehicleProfile",
        "CD_Trip",
        "CD_ChecklistSection",
        "CD_ChecklistGroup",
        "CD_ChecklistItem",
        "CD_LoadedItem",
        "CD_LibraryItem",
        "CD_MaintenanceAttachment",
        "CD_TyrePhoto",
      ]
      for recordType in extraTypes {
        probeLines.append(await probeRecordType(recordType, database: database, zoneID: zoneID))
      }
      let defaultZoneID = CKRecordZone.default().zoneID
      for recordType in [
        CloudKitSidecarPhotoSchema.preferred.recordType,
        CloudKitSidecarPhotoSchema.compatible.recordType,
      ] {
        probeLines.append(
          await probeRecordType(recordType, database: database, zoneID: defaultZoneID)
        )
      }
      let sidecarZoneID = CloudKitSidecarPhotoSchema.sidecarZoneID
      let sidecarZones = zones.filter { $0.zoneID.zoneName == sidecarZoneID.zoneName }
      probeLines.append(
        sidecarZones.isEmpty
          ? "\(CloudKitSidecarPhotoSchema.sidecarZoneName) zone not created yet"
          : "\(CloudKitSidecarPhotoSchema.sidecarZoneName) zone present"
      )
      if sidecarZones.isEmpty {
        probeLines.append("Photo sidecar will create \(CloudKitSidecarPhotoSchema.sidecarZoneName) on first upload")
      } else {
        for recordType in [
          CloudKitSidecarPhotoSchema.productionFallback.recordType,
          CloudKitSidecarPhotoSchema.productionTyreFallback.recordType,
        ] {
          probeLines.append(
            await probeRecordType(recordType, database: database, zoneID: sidecarZoneID)
          )
        }
      }
      cloudKitSchemaDetail = probeLines.joined(separator: "\n")
      SyncDebugLogger.shared.record(category: "schema", message: cloudKitSchemaDetail)
    } catch let error as CKError where error.code == .unknownItem {
      cloudKitSchemaDetail =
        "Schema missing — CD_AppState unknown here. For TestFlight/App Store, deploy the Development schema to Production in CloudKit Console."
      lastErrorDescription = cloudKitSchemaDetail
      SyncDebugLogger.shared.record(category: "schema", message: cloudKitSchemaDetail)
    } catch let error as CKError where error.code == .notAuthenticated {
      cloudKitSchemaDetail = "Cannot probe schema — sign in to iCloud on this device."
      SyncDebugLogger.shared.record(category: "schema", message: cloudKitSchemaDetail)
    } catch {
      if CloudSyncErrorFormatting.isMissingQueryableIndex(error) {
        cloudKitSchemaDetail =
          "Indexes missing — in CloudKit Console mark recordName as Queryable on each CD_* type (Development), then Deploy Schema to Production."
      } else {
        cloudKitSchemaDetail = "Schema probe failed: \(CloudSyncErrorFormatting.description(for: error))"
      }
      lastErrorDescription = cloudKitSchemaDetail
      SyncDebugLogger.shared.record(category: "schema", message: cloudKitSchemaDetail)
      SyncDebugLogger.shared.record(
        category: "schema",
        message: CloudSyncErrorFormatting.dump(for: error)
      )
    }
  }

  func probeExportPoison(in context: ModelContext) async -> String {
    var report = CloudKitExportPoisonAudit.audit(in: context)
    report.cloudDetail = await CloudKitFieldProbe.run(
      containerID: LoadMateModelContainer.cloudKitContainerID,
      local: report.local
    )
    let text = report.formatted
    lastExportPoisonReport = text
    UserDefaults.standard.set(text, forKey: lastExportPoisonDefaultsKey)
    SyncDebugLogger.shared.record(category: "poison", message: text)
    return text
  }

  private func loadLastExportPoisonReport() {
    lastExportPoisonReport = UserDefaults.standard.string(forKey: lastExportPoisonDefaultsKey)
  }

  private func probeRecordType(
    _ recordType: String,
    database: CKDatabase,
    zoneID: CKRecordZone.ID
  ) async -> String {
    do {
      let records = try await CloudKitQueryPaging.fetchAll(
        recordType: recordType,
        database: database,
        zoneID: zoneID
      )
      return "\(recordType) reachable (\(records.count) record\(records.count == 1 ? "" : "s"))"
    } catch let error as CKError where error.code == .unknownItem {
      return "\(recordType) unknown in this environment"
    } catch {
      if CloudSyncErrorFormatting.isMissingQueryableIndex(error) {
        return "\(recordType) present but recordName is not queryable"
      }
      return "\(recordType) probe failed: \(CloudSyncErrorFormatting.description(for: error))"
    }
  }

  private func observeAccountChanges() {
    accountObserver = NotificationCenter.default.addObserver(
      forName: .CKAccountChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        SyncDebugLogger.shared.record(category: "icloud", message: "CKAccountChanged received.")
        await self?.refresh()
      }
    }
  }

  private func observeSyncEvents() {
    syncEventObserver = NotificationCenter.default.addObserver(
      forName: NSPersistentCloudKitContainer.eventChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
          as? NSPersistentCloudKitContainer.Event
      else {
        let keys = (notification.userInfo?.keys.map { String(describing: $0) } ?? []).sorted()
        Task { @MainActor [weak self] in
          SyncDebugLogger.shared.record(
            category: "sync",
            message: "CloudKit event notification received without Event payload. userInfo keys: \(keys.joined(separator: ", "))"
          )
          self?.recordDeepFailure(
            CloudKitDeepErrorInspector.inspect(
              error: nil,
              context: CloudKitDeepErrorInspector.EventContext(
                kind: "UNKNOWN",
                succeeded: false,
                startDate: nil,
                endDate: nil,
                identifier: nil,
                storeIdentifier: nil,
                notificationKeys: keys,
                extraNotificationErrors: Self.errors(in: notification.userInfo),
                countsAtStart: nil,
                countsAtFailure: self?.currentEntityCountsLine(),
                duration: nil,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                pendingMinimalSyncTestID: self?.pendingMinimalSyncTestID
              )
            )
          )
        }
        return
      }

      let keys = (notification.userInfo?.keys.map { String(describing: $0) } ?? []).sorted()
      let extraErrors = Self.errors(in: notification.userInfo)
      Task { @MainActor [weak self] in
        self?.handleSyncEvent(event, notificationKeys: keys, extraNotificationErrors: extraErrors)
      }
    }
    isObservingSyncEvents = true
    SyncDebugLogger.shared.record(
      category: "icloud",
      message: "Observing CloudKit setup/import/export events."
    )
  }

  private func handleSyncEvent(
    _ event: NSPersistentCloudKitContainer.Event,
    notificationKeys: [String],
    extraNotificationErrors: [Error]
  ) {
    seenCloudKitStoreIdentifiers.insert(event.storeIdentifier)
    if let productionIDs = isolationProductionStoreIDs,
       !productionIDs.isEmpty,
       !productionIDs.contains(event.storeIdentifier) {
      return
    }

    let kind = mapEventKind(event.type)
    let started = event.endDate == nil
    let timestamp = started ? event.startDate : (event.endDate ?? Date())
    let timestampText = SyncDebugFormatting.logDateFormatter.string(from: timestamp)
    let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)

    if started {
      let snapshot = currentEntityCounts()
      let counts = snapshot?.logLine ?? "unavailable (no model context registered)"
      let profileIDs = currentProfileIDs()
      inFlightStarts[kind] = (date: event.startDate, counts: snapshot, profileIDs: profileIDs)
      let entry = CloudSyncHistoryEntry.make(
        kind: kind,
        started: true,
        succeeded: false,
        error: nil,
        timestamp: event.startDate
      )
      recordHistory(entry)
      var startMessage = "\(entry.context) at \(timestampText) (uptime \(uptime)s)\nCounts: \(counts)"
      if kind == .importFromCloud {
        startMessage = """
        IMPORT started
        duration pending
        model counts before: \(counts)
        VehicleProfile IDs before: \(profileIDs.count)
        at \(timestampText) (uptime \(uptime)s)
        """
      }
      SyncDebugLogger.shared.record(
        category: "sync",
        message: startMessage
      )
      return
    }

    let finishedAt = event.endDate ?? Date()
    let startInfo = inFlightStarts.removeValue(forKey: kind)
    let startDate = startInfo?.date ?? event.startDate
    let duration = String(format: "%.1fms", finishedAt.timeIntervalSince(startDate) * 1000)
    let countsNowSnapshot = currentEntityCounts()
    let countsNow = countsNowSnapshot?.logLine ?? "unavailable (no model context registered)"
    let errorText = detailedErrorDescription(event.error)
    let summary = CloudSyncEventSummary(
      kind: kind,
      succeeded: event.succeeded,
      finishedAt: finishedAt,
      errorDescription: errorText
    )
    lastSyncEvent = summary

    let entry = CloudSyncHistoryEntry.make(
      kind: kind,
      started: false,
      succeeded: event.succeeded,
      error: event.error,
      timestamp: finishedAt
    )
    recordHistory(entry)

    if event.succeeded {
      switch kind {
      case .importFromCloud:
        lastSuccessfulImportAt = finishedAt
        let before = startInfo?.counts
        let after = countsNowSnapshot
        let beforeIDs = startInfo?.profileIDs ?? []
        let afterIDs = currentProfileIDs()
        let addedIDs = afterIDs.subtracting(beforeIDs)
        let removedIDs = beforeIDs.subtracting(afterIDs)
        var importLines = [
          "IMPORT succeeded",
          "duration: \(duration)",
          "model counts before: \(before?.logLine ?? "unavailable")",
          "model counts after: \(countsNow)",
        ]
        if let before, let after {
          importLines.append(after.deltaDescription(from: before))
          if before.profiles != after.profiles {
            SyncDebugLogger.shared.record(
              category: "cloudkit-import",
              message: "[cloudkit-import] VehicleProfile count changed \(before.profiles) -> \(after.profiles)"
            )
          }
        }
        if !addedIDs.isEmpty {
          importLines.append("New VehicleProfile IDs:")
          importLines.append(contentsOf: addedIDs.sorted { $0.uuidString < $1.uuidString }.map { "  \($0.uuidString)" })
        }
        if !removedIDs.isEmpty {
          importLines.append("Removed VehicleProfile IDs:")
          importLines.append(contentsOf: removedIDs.sorted { $0.uuidString < $1.uuidString }.map { "  \($0.uuidString)" })
        }
        SyncDebugLogger.shared.record(
          category: "sync",
          message: importLines.joined(separator: "\n")
        )
        if let context = modelContext {
          CloudKitDeletionSyncVerifier.shared.noteImport(in: context)
          CloudKitSidecarPhotoSync.shared.reconcile(in: context, includeUploads: true)
        }
      case .exportToCloud:
        lastSuccessfulExportAt = finishedAt
        CloudKitDeletionSyncVerifier.shared.noteExport(succeeded: true)
        if pendingMinimalSyncTestID != nil {
          completeMinimalSyncTest(status: .exportSucceeded)
        }
        SyncDebugLogger.shared.record(
          category: "sync",
          message: "\(entry.context) at \(timestampText) (uptime \(uptime)s, duration \(duration))\nCounts: \(countsNow)"
        )
      case .setup, .unknown:
        SyncDebugLogger.shared.record(
          category: "sync",
          message: "\(entry.context) at \(timestampText) (uptime \(uptime)s, duration \(duration))\nCounts: \(countsNow)"
        )
      }
      return
    }

    if kind == .exportToCloud {
      CloudKitDeletionSyncVerifier.shared.noteExport(succeeded: false)
    }
    if kind == .importFromCloud {
      SyncDebugLogger.shared.record(
        category: "sync",
        message: """
        IMPORT failed
        duration: \(duration)
        model counts before: \(startInfo?.counts?.logLine ?? "unavailable")
        model counts after: \(countsNow)
        """
      )
    }

    lastErrorDescription = errorText ?? "\(entry.context) without an error description."
    SyncDebugLogger.shared.record(
      category: "sync",
      message: CloudKitDeepErrorInspector.startMarker
    )

    let dump = CloudKitDeepErrorInspector.inspect(
      error: event.error,
      context: CloudKitDeepErrorInspector.EventContext(
        kind: kind.displayName.uppercased(),
        succeeded: event.succeeded,
        startDate: startDate,
        endDate: finishedAt,
        identifier: event.identifier.uuidString,
        storeIdentifier: event.storeIdentifier,
        notificationKeys: notificationKeys,
        extraNotificationErrors: extraNotificationErrors,
        countsAtStart: startInfo?.counts?.logLine,
        countsAtFailure: countsNow,
        duration: duration,
        uptimeSeconds: ProcessInfo.processInfo.systemUptime,
        pendingMinimalSyncTestID: pendingMinimalSyncTestID
      )
    )
    recordDeepFailure(dump)
    if kind == .exportToCloud, pendingMinimalSyncTestID != nil {
      completeMinimalSyncTest(status: .exportFailed)
    }
    SyncDebugLogger.shared.record(
      category: "sync",
      message: "\(entry.context) at \(timestampText) (uptime \(uptime)s, duration \(duration))\n\(dump)"
    )
    print("[CloudSync] \(entry.context):\n\(dump)")
  }

  private func recordDeepFailure(_ dump: String) {
    lastDetailedCloudKitFailure = dump
    UserDefaults.standard.set(dump, forKey: lastDetailedFailureDefaultsKey)
  }

  private func loadLastDetailedFailure() {
    lastDetailedCloudKitFailure = UserDefaults.standard.string(forKey: lastDetailedFailureDefaultsKey)
  }

  private func loadMinimalSyncTestStatus() {
    lastMinimalSyncTestID = UserDefaults.standard.string(forKey: minimalSyncIDDefaultsKey)
    if let raw = UserDefaults.standard.string(forKey: minimalSyncStatusDefaultsKey),
       let status = MinimalSyncTestStatus(rawValue: raw) {
      minimalSyncTestStatus = status
      lastMinimalSyncTestResult = displayMinimalSyncStatus(status)
      if status == .waitingForCloudKit || status == .running || status == .localSaveSucceeded {
        pendingMinimalSyncTestID = lastMinimalSyncTestID
        startMinimalSyncTimeout()
      } else {
        pendingMinimalSyncTestID = nil
      }
    }
  }

  private func setMinimalSyncTestStatus(_ status: MinimalSyncTestStatus) {
    minimalSyncTestStatus = status
    lastMinimalSyncTestResult = displayMinimalSyncStatus(status)
    UserDefaults.standard.set(status.rawValue, forKey: minimalSyncStatusDefaultsKey)
    if let identifier = lastMinimalSyncTestID {
      UserDefaults.standard.set(identifier, forKey: minimalSyncIDDefaultsKey)
    }
    SyncDebugLogger.shared.record(
      category: "probe",
      message: "Minimal sync test status: \(lastMinimalSyncTestResult)"
    )
  }

  private func displayMinimalSyncStatus(_ status: MinimalSyncTestStatus) -> String {
    if let id = lastMinimalSyncTestID, status != .notRun {
      return "\(status.rawValue) (\(id))"
    }
    return status.rawValue
  }

  private func startMinimalSyncTimeout() {
    minimalSyncTimeoutTask?.cancel()
    minimalSyncTimeoutTask = Task { @MainActor in
      let nanoseconds = UInt64(CloudKitModelIsolationTester.timeoutSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      guard pendingMinimalSyncTestID != nil,
            minimalSyncTestStatus == .waitingForCloudKit
              || minimalSyncTestStatus == .running
              || minimalSyncTestStatus == .localSaveSucceeded
      else { return }
      completeMinimalSyncTest(status: .timedOut)
    }
  }

  private func completeMinimalSyncTest(status: MinimalSyncTestStatus) {
    minimalSyncTimeoutTask?.cancel()
    minimalSyncTimeoutTask = nil
    setMinimalSyncTestStatus(status)
    pendingMinimalSyncTestID = nil
  }

  private static func errors(in userInfo: [AnyHashable: Any]?) -> [Error] {
    guard let userInfo else { return [] }
    return userInfo.compactMap { key, value in
      if String(describing: key) == String(describing: NSPersistentCloudKitContainer.eventNotificationUserInfoKey) {
        return nil
      }
      return value as? Error
    }
  }

  private func recordHistory(_ entry: CloudSyncHistoryEntry) {
    recentSyncEvents = CloudSyncEventHistory.prepending(entry, onto: recentSyncEvents)
    persistEventHistory()
  }

  private func loadEventHistory() {
    guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey),
          let decoded = try? historyDecoder.decode([CloudSyncHistoryEntry].self, from: data)
    else { return }
    recentSyncEvents = Array(decoded.prefix(CloudSyncEventHistory.maxEntries))
  }

  private func persistEventHistory() {
    guard let data = try? historyEncoder.encode(recentSyncEvents) else { return }
    UserDefaults.standard.set(data, forKey: historyDefaultsKey)
  }

  private func map(_ status: CKAccountStatus) -> CloudSyncAccountStatus {
    switch status {
    case .available: return .available
    case .noAccount: return .noAccount
    case .restricted: return .restricted
    case .couldNotDetermine: return .couldNotDetermine
    case .temporarilyUnavailable: return .temporarilyUnavailable
    @unknown default: return .couldNotDetermine
    }
  }

  private func mapEventKind(_ type: NSPersistentCloudKitContainer.EventType) -> CloudSyncEventKind {
    switch type {
    case .setup: return .setup
    case .import: return .importFromCloud
    case .export: return .exportToCloud
    @unknown default: return .unknown
    }
  }

  private func detailedErrorDescription(_ error: Error?) -> String? {
    guard let error else { return nil }
    return CloudSyncErrorFormatting.description(for: error)
  }
}

enum CloudSyncErrorFormatting {
  private static let maxPartialItems = 25
  private static let maxUserInfoValueLength = 500
  private static let partialErrorsUserInfoKey = "CKPartialErrorsByItemIDKey"

  static func description(for error: Error) -> String {
    flatten(error).joined(separator: " | ")
  }

  /// Multi-line dump for the sync debug log and Xcode console.
  static func dump(for error: Error) -> String {
    flatten(error).joined(separator: "\n")
  }

  static func isMissingQueryableIndex(_ error: Error) -> Bool {
    flatten(error).contains { $0.localizedCaseInsensitiveContains("not marked queryable") }
  }

  static func isPartialFailure(_ error: Error) -> Bool {
    flatten(error).contains { $0.contains("PARTIAL FAILURE") }
  }

  /// SwiftData model names involved in the error, with no record IDs or user content.
  static func involvedModels(in error: Error) -> [String] {
    var seenErrors = Set<String>()
    var seenModels = Set<String>()
    var models: [String] = []
    collectInvolvedModels(
      from: error,
      depth: 0,
      seenErrors: &seenErrors,
      seenModels: &seenModels,
      models: &models
    )
    return models
  }

  static func flatten(_ error: Error, depth: Int = 0) -> [String] {
    var seen = Set<String>()
    return flatten(error, depth: depth, seen: &seen)
  }

  private static func flatten(_ error: Error, depth: Int, seen: inout Set<String>) -> [String] {
    guard depth < 6 else { return ["…nested error truncated"] }
    let nsError = error as NSError
    var parts = [headline(nsError, depth: depth)]

    if let retryAfter = retryAfterSeconds(from: nsError) {
      parts.append("Retry after: \(retryAfter)s")
    }
    if let userInfo = summarizedUserInfo(nsError) {
      let label = depth > 0 ? "Nested userInfo" : "UserInfo"
      parts.append("\(label): \(userInfo)")
    }

    if let partial = partialErrorMap(from: nsError) {
      let items = partial.sorted { describeItemID($0.key) < describeItemID($1.key) }
      parts.append("⚠️ CloudKit PARTIAL FAILURE - \(items.count) item\(items.count == 1 ? "" : "s")")
      for (itemID, itemError) in items.prefix(maxPartialItems) {
        parts.append("Failed item: \(describeItemID(itemID))")
        if let context = recordContext(itemID: itemID, error: itemError as NSError) {
          parts.append("Record type / model: \(context)")
        }
        parts.append("Error: \(itemError)")
        parts.append(contentsOf: flatten(itemError, depth: depth + 1, seen: &seen))
      }
      if items.count > maxPartialItems {
        parts.append("… \(items.count - maxPartialItems) more failed items omitted")
      }
    }

    for inner in nestedErrorsExcludingPartialMap(in: nsError) {
      let innerNS = inner as NSError
      let key = "\(innerNS.domain):\(innerNS.code):\(innerNS.localizedDescription)"
      guard seen.insert(key).inserted else { continue }
      if let underlyingHint = underlyingErrorLabel(for: nsError, inner: innerNS) {
        parts.append(underlyingHint)
      }
      parts.append(contentsOf: flatten(inner, depth: depth + 1, seen: &seen))
    }
    return parts
  }

  private static func headline(_ nsError: NSError, depth: Int) -> String {
    let line: String
    if nsError.domain == CKErrorDomain {
      let code = CKError.Code(rawValue: nsError.code)
      let name = ckCodeName(code)
      if depth == 0 {
        line = "☁️ CloudKit error: \(nsError.code) (\(name)): \(nsError.localizedDescription)"
      } else {
        line = "Nested CKError: \(nsError.code) (\(name)): \(nsError.localizedDescription)"
      }
    } else if nsError.domain == NSCocoaErrorDomain {
      line = "\(nsError.localizedDescription) [CocoaError \(nsError.code)]"
    } else {
      line = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
    if let reason = nsError.localizedFailureReason,
       reason != nsError.localizedDescription,
       !line.contains(reason) {
      return "\(line) — \(reason)"
    }
    return line
  }

  private static func partialErrorMap(from nsError: NSError) -> [AnyHashable: Error]? {
    if let ckError = nsError as? CKError, let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
      return partial
    }
    let userInfo = nsError.userInfo
    if let map = userInfo[partialErrorsUserInfoKey] as? [AnyHashable: Error], !map.isEmpty {
      return map
    }
    if let map = userInfo[partialErrorsUserInfoKey] as? [AnyHashable: NSError], !map.isEmpty {
      return map.mapValues { $0 as Error }
    }
    return nil
  }

  private static func nestedErrorsExcludingPartialMap(in nsError: NSError) -> [Error] {
    var nested: [Error] = []
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      nested.append(underlying)
    }
    if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [Error] {
      nested.append(contentsOf: detailed)
    } else if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [NSError] {
      nested.append(contentsOf: detailed.map { $0 as Error })
    }
    return nested
  }

  private static func underlyingErrorLabel(for nsError: NSError, inner: NSError) -> String? {
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == inner.domain, underlying.code == inner.code {
      return "Underlying error:"
    }
    return nil
  }

  private static func retryAfterSeconds(from nsError: NSError) -> Double? {
    if let ckError = nsError as? CKError, let seconds = ckError.retryAfterSeconds {
      return seconds
    }
    if let number = nsError.userInfo["CKErrorRetryAfterKey"] as? NSNumber {
      return number.doubleValue
    }
    return nil
  }

  private static func summarizedUserInfo(_ nsError: NSError) -> String? {
    let omitted: Set<String> = [
      NSLocalizedDescriptionKey,
      NSUnderlyingErrorKey,
      NSDetailedErrorsKey,
      partialErrorsUserInfoKey
    ]
    var pairs: [String] = []
    let keys = nsError.userInfo.keys.sorted { String(describing: $0) < String(describing: $1) }
    for key in keys {
      let keyString = String(describing: key)
      if omitted.contains(keyString) { continue }
      guard let value = nsError.userInfo[key] else { continue }
      pairs.append("\(keyString)=\(describeUserInfoValue(value))")
    }
    guard !pairs.isEmpty else { return nil }
    return "{\(pairs.joined(separator: ", "))}"
  }

  private static func describeUserInfoValue(_ value: Any) -> String {
    if let record = value as? CKRecord {
      return "CKRecord(type=\(record.recordType), id=\(record.recordID.recordName))"
    }
    if let recordID = value as? CKRecord.ID {
      return describeItemID(recordID)
    }
    if let data = value as? Data {
      return "<\(data.count) bytes>"
    }
    if let error = value as? NSError, value is Error {
      return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }
    if let map = value as? [AnyHashable: NSError] {
      return "<\(map.count) item error\(map.count == 1 ? "" : "s")>"
    }
    let raw = String(describing: value)
    if raw.count <= maxUserInfoValueLength { return raw }
    return String(raw.prefix(maxUserInfoValueLength)) + "…"
  }

  private static func ckRecordID(from itemID: AnyHashable) -> CKRecord.ID? {
    itemID as? CKRecord.ID ?? itemID.base as? CKRecord.ID
  }

  private static func ckZoneID(from itemID: AnyHashable) -> CKRecordZone.ID? {
    itemID as? CKRecordZone.ID ?? itemID.base as? CKRecordZone.ID
  }

  private static func describeItemID(_ itemID: AnyHashable) -> String {
    if let recordID = ckRecordID(from: itemID) {
      return "CKRecord.ID recordName=\(recordID.recordName) zone=\(recordID.zoneID.zoneName) owner=\(recordID.zoneID.ownerName)"
    }
    if let zoneID = ckZoneID(from: itemID) {
      return "CKRecordZone.ID zone=\(zoneID.zoneName) owner=\(zoneID.ownerName)"
    }
    return String(describing: itemID)
  }

  private static func recordContext(itemID: AnyHashable, error nsError: NSError) -> String? {
    var seen = Set<String>()
    var types: [String] = []

    func add(_ raw: String) {
      guard seen.insert(raw).inserted else { return }
      types.append(raw)
    }

    if let recordID = ckRecordID(from: itemID) {
      extractRecordTypes(from: recordID.recordName).forEach(add)
    }

    for value in nsError.userInfo.values {
      if let record = value as? CKRecord {
        add(record.recordType)
      }
      if let text = value as? String {
        extractRecordTypes(from: text).forEach(add)
      }
    }
    extractRecordTypes(from: nsError.localizedDescription).forEach(add)
    if let reason = nsError.localizedFailureReason {
      extractRecordTypes(from: reason).forEach(add)
    }
    if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
      extractRecordTypes(from: debug).forEach(add)
    }

    guard !types.isEmpty else { return nil }
    return types.map { type in
      if type.hasPrefix("CD_") {
        let model = String(type.dropFirst(3))
        return "\(type) (SwiftData: \(model))"
      }
      return type
    }.joined(separator: ", ")
  }

  private static func extractRecordTypes(from text: String) -> [String] {
    text.matches(of: /CD_[A-Za-z][A-Za-z0-9]*/).map { String($0.output) }
  }

  private static func collectInvolvedModels(
    from error: Error,
    depth: Int,
    seenErrors: inout Set<String>,
    seenModels: inout Set<String>,
    models: inout [String]
  ) {
    guard depth < 6 else { return }
    let nsError = error as NSError
    let errorKey = "\(nsError.domain):\(nsError.code):\(nsError.localizedDescription)"
    guard seenErrors.insert(errorKey).inserted else { return }

    func addRecordType(_ raw: String) {
      guard raw.hasPrefix("CD_") else { return }
      let model = String(raw.dropFirst(3))
      guard seenModels.insert(model).inserted else { return }
      models.append(model)
    }

    extractRecordTypes(from: nsError.localizedDescription).forEach(addRecordType)
    if let reason = nsError.localizedFailureReason {
      extractRecordTypes(from: reason).forEach(addRecordType)
    }
    if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
      extractRecordTypes(from: debug).forEach(addRecordType)
    }
    for value in nsError.userInfo.values {
      if let record = value as? CKRecord {
        addRecordType(record.recordType)
      }
      if let text = value as? String {
        extractRecordTypes(from: text).forEach(addRecordType)
      }
    }

    if let partial = partialErrorMap(from: nsError) {
      for (itemID, itemError) in partial {
        if let recordID = ckRecordID(from: itemID) {
          extractRecordTypes(from: recordID.recordName).forEach(addRecordType)
        }
        collectInvolvedModels(
          from: itemError,
          depth: depth + 1,
          seenErrors: &seenErrors,
          seenModels: &seenModels,
          models: &models
        )
      }
    }

    for inner in nestedErrorsExcludingPartialMap(in: nsError) {
      collectInvolvedModels(
        from: inner,
        depth: depth + 1,
        seenErrors: &seenErrors,
        seenModels: &seenModels,
        models: &models
      )
    }
  }

  static func ckCodeName(_ code: CKError.Code?) -> String {
    switch code {
    case .internalError: return "internalError"
    case .partialFailure: return "partialFailure"
    case .networkUnavailable: return "networkUnavailable"
    case .networkFailure: return "networkFailure"
    case .badContainer: return "badContainer"
    case .serviceUnavailable: return "serviceUnavailable"
    case .requestRateLimited: return "requestRateLimited"
    case .missingEntitlement: return "missingEntitlement"
    case .notAuthenticated: return "notAuthenticated"
    case .permissionFailure: return "permissionFailure"
    case .unknownItem: return "unknownItem"
    case .invalidArguments: return "invalidArguments"
    case .resultsTruncated: return "resultsTruncated"
    case .serverRecordChanged: return "serverRecordChanged"
    case .serverRejectedRequest: return "serverRejectedRequest"
    case .assetFileNotFound: return "assetFileNotFound"
    case .assetFileModified: return "assetFileModified"
    case .incompatibleVersion: return "incompatibleVersion"
    case .constraintViolation: return "constraintViolation"
    case .operationCancelled: return "operationCancelled"
    case .changeTokenExpired: return "changeTokenExpired"
    case .batchRequestFailed: return "batchRequestFailed"
    case .zoneBusy: return "zoneBusy"
    case .badDatabase: return "badDatabase"
    case .quotaExceeded: return "quotaExceeded"
    case .zoneNotFound: return "zoneNotFound"
    case .limitExceeded: return "limitExceeded"
    case .userDeletedZone: return "userDeletedZone"
    case .tooManyParticipants: return "tooManyParticipants"
    case .alreadyShared: return "alreadyShared"
    case .referenceViolation: return "referenceViolation"
    case .managedAccountRestricted: return "managedAccountRestricted"
    case .participantMayNeedVerification: return "participantMayNeedVerification"
    case .participantAlreadyInvited: return "participantAlreadyInvited"
    case .serverResponseLost: return "serverResponseLost"
    case .assetNotAvailable: return "assetNotAvailable"
    case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
    case .none: return "unknown"
    @unknown default: return "other"
    }
  }
}
