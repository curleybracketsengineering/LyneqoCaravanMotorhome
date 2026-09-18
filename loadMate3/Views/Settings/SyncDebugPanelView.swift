import SwiftData
import SwiftUI

struct SyncDebugPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var cloudSync: CloudSyncMonitor
    @ObservedObject private var isolationTester = CloudKitModelIsolationTester.shared
    @ObservedObject private var deletionVerifier = CloudKitDeletionSyncVerifier.shared
    @ObservedObject private var assetCanary = CloudKitAssetCanary.shared

    let appState: AppState?
    let activeProfileName: String?

    @ObservedObject private var logger = SyncDebugLogger.shared
    @State private var counts = Counts()
    @State private var copyConfirmation = ""
    @State private var auditReport: CloudKitDiagnosticAuditReport?
    @State private var healthReport: CloudKitProductionHealthReport?
    @State private var removalPreview = ""
    @State private var removalResult = ""
    @State private var incrementalSeedResult = ""
    #if DEBUG
    @State private var suppressAutomaticSeeding = SyncDebugSeedIsolation.isAutomaticSeedingSuppressed
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppScreenMetrics.sectionSpacing) {
                    AppHeroSection(
                        systemImage: "ladybug",
                        title: "Sync Debug",
                        subtitle: "Hidden developer-only iCloud diagnostics. Tests are numbered 1 to 34 from top to bottom."
                    )

                    numberedTestsSection()
                    statusSection()
                    countsSection()
                    lastDetailedFailureSection()
                    cloudKitEnvironmentSection()
                    syncHistorySection()
                    logSection()
                }
                .padding(.horizontal, AppScreenMetrics.horizontalPadding)
                .padding(.top, AppScreenMetrics.verticalScreenPadding)
                .padding(.bottom, AppScreenMetrics.bottomScrollPadding)
            }
            .appScreenBackground()
            .navigationTitle("Sync Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                refreshCounts()
                cloudSync.refreshPushRegistrationStatus()
                SyncDebugLogger.shared.record(category: "panel", message: "Opened sync debug panel.")
            }
        }
    }

    @ViewBuilder
    private func numberedTestsSection() -> some View {
        AppSettingsSection(
            "Tests",
            caption: "In number order from 1 to 34. Next photo-sync test is 34."
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.refreshICloud, "Refresh iCloud Status")) {
                    Task {
                        await cloudSync.refresh()
                        refreshCounts()
                    }
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.checkSchema, "Check CloudKit Schema")) {
                    Task {
                        await cloudSync.probeCloudKitSchema()
                    }
                }

                statusRow("Sequence", value: "\(appState?.syncProbeSequence ?? 0)")
                statusRow("Updated", value: SyncDebugFormatting.string(for: appState?.syncProbeUpdatedAt))
                statusRow("Device", value: probeDeviceText)
                statusRow("Value", value: probeValueText)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.writeSyncProbe, "Write Sync Probe")) {
                    writeSyncProbe()
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.minimalSync, "Run Minimal Sync Test")) {
                    runMinimalSyncTest()
                }

                Text(cloudSync.lastMinimalSyncTestResult)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.compareLocalVsCloudKit, "Compare Local vs CloudKit")) {
                    Task {
                        _ = await cloudSync.probeExportPoison(in: modelContext)
                    }
                }
                if let dump = cloudSync.lastExportPoisonReport, !dump.isEmpty {
                    Text(dump)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.productionHealth, "Run Production Sync Health Check")) {
                    healthReport = CloudKitProductionHealth.report(monitor: cloudSync, context: modelContext)
                    if let healthReport {
                        logger.record(category: "health", message: healthReport.formatted)
                    }
                }
                if let healthReport {
                    Text(healthReport.formatted)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.diagnosticAudit, "Run Diagnostic Data Audit")) {
                    let report = CloudKitDiagnosticAuditor.audit(in: modelContext)
                    auditReport = report
                    removalPreview = report.removalPreview
                    logger.record(category: "audit", message: report.formatted)
                }
                if let auditReport {
                    Text(auditReport.formatted)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !removalPreview.isEmpty {
                    Text(removalPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.copyDebugReport, "Copy Debug Report")) {
                    refreshCounts()
                    let report = logger.makeReport(snapshot: snapshot())
                    copyConfirmation = logger.copyReport(report) ? "Report copied to clipboard." : "Clipboard not available on this platform."
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.logModelAudit, "Log Model Audit")) {
                    logger.record(category: "schema", message: CloudKitModelAudit.report())
                    copyConfirmation = "Model audit written to the local log and included in Copy Debug Report."
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.removeDiagnosticRecords, "Remove Clearly Diagnostic Records")) {
                    Task { await removeClearlyDiagnosticRecords() }
                }
                .disabled(auditReport?.removalPlan.removable.isEmpty != false)
                if !removalResult.isEmpty {
                    Text(removalResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.clearLocalLog, "Clear Local Log")) {
                    logger.clear()
                    copyConfirmation = "Cleared local sync log, CloudKit event history, and last detailed CloudKit failure."
                }

                Text("12–17 write to CloudKit and stay disabled against production.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationAppState, "Run AppState-Only CloudKit Test")) {
                    Task { await isolationTester.runAppStateOnlyTest() }
                }
                .disabled(true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationCoreVehicle, "Run Core Vehicle CloudKit Test")) {
                    Task { await isolationTester.runCoreVehicleTest() }
                }
                .disabled(true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationChecklist, "Run Checklist Model CloudKit Test")) {
                    Task { await isolationTester.runChecklistTest() }
                }
                .disabled(true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationChecklistGroup, "Run ChecklistGroup CloudKit Test")) {
                    Task { await isolationTester.runChecklistGroupTest() }
                }
                .disabled(true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationLoadedItem, "Run LoadedItem CloudKit Test")) {
                    Task { await isolationTester.runLoadedItemTest() }
                }
                .disabled(true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.isolationLibraryItem, "Run LibraryItem CloudKit Test")) {
                    Task { await isolationTester.runLibraryItemTest() }
                }
                .disabled(true)

                Text(isolationTester.lastFormattedReport)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("18 is a SwiftData JPEG (failed). 32 and 33 are metadata (passed). 34 tests the real photo sidecar (plates, tyres, documents). On TestFlight this uses an existing CloudKit type in a separate zone. A pass on this device is not enough — confirm the photo appears on the other device.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.tinyAssetCanary, "Run Tiny Asset Canary")) {
                    Task {
                        await assetCanary.runFileOnlyCanary(in: modelContext, monitor: cloudSync)
                    }
                }
                .disabled(assetCanary.isRunning)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.tinyAssetCanaryWithThumbnail, "Run Tiny Asset Canary With Thumbnail")) {
                    Task {
                        await assetCanary.runThumbnailCanary(in: modelContext, monitor: cloudSync)
                    }
                }
                .disabled(assetCanary.isRunning)

                Text(assetCanary.lastReport)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(
                    Array(LoadMateChecklistSeedTemplate.sections(for: incrementalSeedTargetProfile?.kind ?? .caravan).enumerated()),
                    id: \.element.templateOrder
                ) { index, section in
                    AppSecondaryButton(
                        SyncDebugTestCatalog.title(
                            SyncDebugTestCatalog.seedSectionNumber(section.templateOrder),
                            section.debugButtonTitle
                        )
                    ) {
                        let result = LoadMateChecklistSeedTemplate.insertSection(
                            at: index,
                            onto: incrementalSeedTargetProfile,
                            in: modelContext
                        )
                        incrementalSeedResult = result.userMessage
                        refreshCounts()
                    }
                }
                if !incrementalSeedResult.isEmpty {
                    Text(incrementalSeedResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let profiles = VehicleProfileStore.uniqueSortedProfiles(
                    (try? modelContext.fetch(FetchDescriptor<VehicleProfile>())) ?? []
                )
                ForEach(profiles, id: \.id) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        AppSecondaryButton(
                            SyncDebugTestCatalog.title(
                                SyncDebugTestCatalog.watchVehicle,
                                "Watch \(profile.kind.displayName) …\(profile.id.uuidString.suffix(4))"
                            )
                        ) {
                            deletionVerifier.startWatching(
                                profile: profile,
                                counts: SyncDebugEntityCounts.fetch(from: modelContext)
                            )
                        }
                        Text(profile.id.uuidString)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppColors.textSupporting)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.checkWatchedVehicle, "Check whether watched vehicle reappeared")) {
                    deletionVerifier.checkReimport(in: modelContext)
                }
                .disabled(deletionVerifier.watchedID == nil)
                Text(deletionVerifier.formattedStatus())
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.documentOnlyCanary, "Run Document Canary (No File)")) {
                    Task {
                        await assetCanary.runDocumentOnlyCanary(in: modelContext, monitor: cloudSync)
                    }
                }
                .disabled(assetCanary.isRunning)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.attachmentMetaCanary, "Run Attachment Canary (No Bytes)")) {
                    Task {
                        await assetCanary.runAttachmentMetaCanary(in: modelContext, monitor: cloudSync)
                    }
                }
                .disabled(assetCanary.isRunning)

                AppSecondaryButton(SyncDebugTestCatalog.title(SyncDebugTestCatalog.sidecarCKAssetCanary, "Run Sidecar CKAsset Canary")) {
                    Task {
                        await assetCanary.runSidecarCKAssetCanary()
                    }
                }
                .disabled(assetCanary.isRunning)

                Text(assetCanary.lastReport)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                #if DEBUG
                Toggle("Suppress automatic seeding", isOn: $suppressAutomaticSeeding)
                    .onChange(of: suppressAutomaticSeeding) { _, newValue in
                        SyncDebugSeedIsolation.setAutomaticSeedingSuppressed(newValue)
                    }
                Text("Automatic factory seed is already disabled for this build. This DEBUG toggle only matters if that policy is turned back on.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
                #endif

                if !copyConfirmation.isEmpty {
                    Text(copyConfirmation)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSupporting)
                }
            }
        }
    }

    @ViewBuilder
    private func statusSection() -> some View {
        AppSettingsSection(
            "Status",
            caption: "What this device currently knows about iCloud and the app build."
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                statusRow("iCloud", value: cloudSync.accountStatus.settingsTitle)
                statusRow("Checked", value: SyncDebugFormatting.string(for: cloudSync.lastCheckedAt))
                statusRow("Last error", value: cloudSync.lastErrorDescription ?? "None")
                statusRow("Last CloudKit event", value: lastSyncEventText)
                statusRow("Last import OK", value: SyncDebugFormatting.string(for: cloudSync.lastSuccessfulImportAt))
                statusRow("Last export OK", value: SyncDebugFormatting.string(for: cloudSync.lastSuccessfulExportAt))
                statusRow("Push registered", value: cloudSync.isRegisteredForRemoteNotifications ? "Yes" : "No")
                statusRow("Push detail", value: cloudSync.pushRegistrationDetail)
                statusRow("CloudKit schema", value: cloudSync.cloudKitSchemaDetail)
                statusRow("Minimal sync test", value: cloudSync.lastMinimalSyncTestResult)
                statusRow("Device", value: SyncDebugFormatting.deviceName)
                statusRow("Bundle", value: SyncDebugFormatting.bundleID)
                statusRow("Version", value: "\(SyncDebugFormatting.appVersion) (\(SyncDebugFormatting.buildNumber))")
                statusRow("CloudKit", value: LoadMateModelContainer.cloudKitContainerID)
                statusRow("Active profile", value: activeProfileName ?? "None")
            }
        }
    }

    @ViewBuilder
    private func lastDetailedFailureSection() -> some View {
        AppSettingsSection(
            "Last Detailed CloudKit Failure",
            caption: "Kept until another CloudKit failure replaces it, or you clear diagnostics. Closing this panel does not erase it."
        ) {
            if let dump = cloudSync.lastDetailedCloudKitFailure, !dump.isEmpty {
                Text(dump)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None yet")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            }
        }
    }

    @ViewBuilder
    private func cloudKitEnvironmentSection() -> some View {
        AppSettingsSection(
            "CloudKit Environment",
            caption: "Production and diagnostic CloudKit containers are separate. Isolation tests must not write to production."
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                statusRow("Production container", value: CloudKitEnvironment.productionContainerID)
                statusRow("Diagnostic container", value: CloudKitEnvironment.diagnosticContainerStatusLine)
                statusRow("Isolation tests", value: CloudKitEnvironment.isolationStatusLine)
                statusRow("Automatic seed", value: LoadMateSeedPolicy.statusLine)
                Text(CloudKitEnvironment.diagnosticContainerSetupSteps)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func syncHistorySection() -> some View {
        AppSettingsSection(
            "CloudKit Event History",
            caption: "The last \(CloudSyncEventHistory.maxEntries) import, export, and setup events. Model and operation names only — no personal data."
        ) {
            if cloudSync.recentSyncEvents.isEmpty {
                Text("No CloudKit events recorded yet.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            } else {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    ForEach(cloudSync.recentSyncEvents) { event in
                        statusRow(
                            SyncDebugFormatting.string(for: event.timestamp),
                            value: event.context
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func countsSection() -> some View {
        AppSettingsSection(
            "Entity Counts",
            caption: "Use these counts to spot missing imports or duplicate local state."
        ) {
            VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                statusRow("Vehicle profiles", value: "\(counts.vehicleProfiles)")
                statusRow("Trips", value: "\(counts.trips)")
                statusRow("Loaded items", value: "\(counts.loadedItems)")
                statusRow("Library items", value: "\(counts.libraryItems)")
                statusRow("Checklist sections", value: "\(counts.checklistSections)")
                statusRow("Checklist items", value: "\(counts.checklistItems)")
                statusRow("AppState rows", value: "\(counts.appStates)")
            }
        }
    }

    @ViewBuilder
    private func logSection() -> some View {
        AppSettingsSection(
            "Recent Log",
            caption: "Local rolling log of save attempts, probe writes, and iCloud checks."
        ) {
            if logger.entries.isEmpty {
                Text("No log entries yet.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSupporting)
            } else {
                VStack(alignment: .leading, spacing: AppScreenMetrics.controlSpacing) {
                    ForEach(logger.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("[\(entry.category.uppercased())] \(SyncDebugFormatting.string(for: entry.timestamp))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                            Text(entry.message)
                                .font(.caption)
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if entry.id != logger.entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func writeSyncProbe() {
        guard let appState else { return }

        let sequence = appState.syncProbeSequence + 1
        let deviceName = SyncDebugFormatting.deviceName
        let timestamp = Date()

        appState.syncProbeSequence = sequence
        appState.syncProbeUpdatedAt = timestamp
        appState.syncProbeUpdatedBy = deviceName
        appState.syncProbeValue = "\(deviceName) @ \(SyncDebugFormatting.displayDateFormatter.string(from: timestamp))"

        if SyncDebugSaveHelper.save(modelContext, source: "SyncDebugPanel.writeSyncProbe") {
            logger.record(
                category: "probe",
                message: "Wrote sync probe #\(sequence) from \(deviceName)."
            )
            refreshCounts()
        }
    }

    private func runMinimalSyncTest() {
        let state: AppState
        if let appState {
            state = appState
        } else {
            state = AppStateStore.resolve(in: modelContext)
        }

        let identifier = "min-sync-\(UUID().uuidString)"
        cloudSync.beginMinimalSyncTest(identifier: identifier)
        state.syncProbeSequence += 1
        state.syncProbeValue = identifier
        state.syncProbeUpdatedAt = Date()
        state.syncProbeUpdatedBy = SyncDebugFormatting.deviceName

        logger.record(category: "probe", message: "Minimal sync test record created (\(identifier))")
        let saved = SyncDebugSaveHelper.save(modelContext, source: "SyncDebugPanel.runMinimalSyncTest")
        logger.record(
            category: "probe",
            message: saved ? "Local save succeeded" : "Local save failed"
        )
        cloudSync.noteMinimalSyncLocalSave(succeeded: saved)
        if saved {
            logger.record(category: "probe", message: "Waiting for CloudKit export event")
        }
        refreshCounts()
    }

    private func refreshCounts() {
        counts = Counts(
            vehicleProfiles: fetchCount(FetchDescriptor<VehicleProfile>()),
            trips: fetchCount(FetchDescriptor<Trip>()),
            loadedItems: fetchCount(FetchDescriptor<LoadedItem>()),
            libraryItems: fetchCount(FetchDescriptor<LibraryItem>()),
            checklistSections: fetchCount(FetchDescriptor<ChecklistSection>()),
            checklistItems: fetchCount(FetchDescriptor<ChecklistItem>()),
            appStates: fetchCount(FetchDescriptor<AppState>())
        )
    }

    @MainActor
    private func removeClearlyDiagnosticRecords() async {
        guard let auditReport, !auditReport.removalPlan.removable.isEmpty else { return }
        do {
            let removed = try CloudKitDiagnosticAuditor.removeClearlyDiagnosticRecords(in: modelContext)
            let saved = SyncDebugSaveHelper.save(modelContext, source: "SyncDebugPanel.removeDiagnostic")
            logger.record(category: "audit", message: removed)
            logger.record(category: "audit", message: saved ? "Local save succeeded" : "Local save failed")
            let exported = await cloudSync.waitForNextExport()
            removalResult = """
            \(removed)
            Local save: \(saved ? "succeeded" : "failed")
            CloudKit export after cleanup: \(exported ? "succeeded" : "not seen / failed")
            """
            self.auditReport = CloudKitDiagnosticAuditor.audit(in: modelContext)
            removalPreview = self.auditReport?.removalPreview ?? ""
            refreshCounts()
        } catch {
            removalResult = "Remove failed: \(error.localizedDescription)"
        }
    }

    private func fetchCount<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) -> Int {
        (try? modelContext.fetch(descriptor).count) ?? 0
    }

    private func snapshot() -> SyncDebugSnapshot {
        SyncDebugSnapshot(
            accountStatus: cloudSync.accountStatus,
            lastCheckedAt: cloudSync.lastCheckedAt,
            lastErrorDescription: cloudSync.lastErrorDescription,
            lastSyncEventSummary: lastSyncEventText,
            recentSyncEventLines: cloudSync.recentSyncEvents.map(\.displayLine),
            lastSuccessfulImportAt: cloudSync.lastSuccessfulImportAt,
            lastSuccessfulExportAt: cloudSync.lastSuccessfulExportAt,
            lastDetailedCloudKitFailure: cloudSync.lastDetailedCloudKitFailure,
            lastMinimalSyncTestResult: cloudSync.lastMinimalSyncTestResult,
            lastAssetCanaryResult: CloudKitAssetCanary.shared.lastReport,
            cloudKitIsolationTestReport: isolationTester.lastFormattedReport,
            isRegisteredForRemoteNotifications: cloudSync.isRegisteredForRemoteNotifications,
            pushRegistrationDetail: cloudSync.pushRegistrationDetail,
            cloudKitSchemaDetail: cloudSync.cloudKitSchemaDetail,
            exportPoisonReport: cloudSync.lastExportPoisonReport ?? "",
            deviceName: SyncDebugFormatting.deviceName,
            bundleID: SyncDebugFormatting.bundleID,
            appVersion: SyncDebugFormatting.appVersion,
            buildNumber: SyncDebugFormatting.buildNumber,
            vehicleProfileCount: counts.vehicleProfiles,
            tripCount: counts.trips,
            loadedItemCount: counts.loadedItems,
            libraryItemCount: counts.libraryItems,
            checklistSectionCount: counts.checklistSections,
            checklistItemCount: counts.checklistItems,
            appStateCount: counts.appStates,
            activeProfileName: activeProfileName,
            syncProbeSequence: appState?.syncProbeSequence ?? 0,
            syncProbeValue: appState?.syncProbeValue ?? "",
            syncProbeUpdatedAt: appState?.syncProbeUpdatedAt,
            syncProbeUpdatedBy: appState?.syncProbeUpdatedBy ?? ""
        )
    }

    private var incrementalSeedTargetProfile: VehicleProfile? {
        let profiles = (try? modelContext.fetch(FetchDescriptor<VehicleProfile>())) ?? []
        return VehicleProfileStore.activeProfile(profiles: profiles, appState: appState)
    }

    private var lastSyncEventText: String {
        guard let event = cloudSync.lastSyncEvent else { return "None yet" }
        let result = event.succeeded ? "OK" : "FAILED"
        let when = SyncDebugFormatting.string(for: event.finishedAt)
        if let error = event.errorDescription, !error.isEmpty {
            return "\(event.kind.displayName) \(result) @ \(when) — \(error)"
        }
        return "\(event.kind.displayName) \(result) @ \(when)"
    }

    @ViewBuilder
    private func statusRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var probeDeviceText: String {
        guard let value = appState?.syncProbeUpdatedBy, !value.isEmpty else { return "None" }
        return value
    }

    private var probeValueText: String {
        guard let value = appState?.syncProbeValue, !value.isEmpty else { return "None" }
        return value
    }
}

private extension SyncDebugPanelView {
    struct Counts {
        var vehicleProfiles: Int = 0
        var trips: Int = 0
        var loadedItems: Int = 0
        var libraryItems: Int = 0
        var checklistSections: Int = 0
        var checklistItems: Int = 0
        var appStates: Int = 0
    }
}
