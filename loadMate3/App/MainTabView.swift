import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case home
    case load
    case safety
    case care
    case more
}

struct MainTabView: View {
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]
    @ObservedObject private var sidecarPhotos = CloudKitSidecarPhotoSync.shared

    @State private var selectedTab: AppTab = .home
    @State private var selectedPadTab: PadTab = .summary
    @State private var loadWorkflowStep: LoadWorkflowStep = .items
    @State private var pendingCareDestination: CareDestination?
    @State private var showSetupAlert = false
    @State private var didPresentSetupPrompt = false
    @State private var isPadLayoutActive = AppLayout.defaultUsePadLayout
    @State private var padAvailableWidth: CGFloat = UIScreen.main.bounds.width

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(profiles: profiles, appState: AppStateStore.canonical(from: appStates))
    }

    private var needsSetup: Bool {
        guard let profile = activeProfile else { return true }
        return !profile.isConfiguredForWeightCalculations
    }

    var body: some View {
        let _ = sidecarPhotos.revision
        Group {
            if isPadLayoutActive {
                padTabRoot(availableWidth: padAvailableWidth)
            } else {
                phoneTabRoot
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: AvailableWidthKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(AvailableWidthKey.self) { width in
            guard width > 0 else { return }
            let usePad = AppLayout.usePadLayout(availableWidth: width)
            if usePad != isPadLayoutActive {
                isPadLayoutActive = usePad
            }
            if usePad {
                padAvailableWidth = width
            }
        }
        .environment(\.usePadLayout, isPadLayoutActive)
        .environment(\.padTopTabBarActive, isPadLayoutActive)
        .onAppear {
            presentSetupPromptIfNeeded()
        }
        .onChange(of: needsSetup) { _, _ in
            presentSetupPromptIfNeeded()
        }
        .alert(setupAlertTitle, isPresented: $showSetupAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(setupAlertMessage)
        }
    }

    // MARK: - iPad

    private func padTabRoot(availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            PadTabBar(selection: $selectedPadTab, availableWidth: availableWidth)

            padTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyneqoTheme.background)
    }

    @ViewBuilder
    private var padTabContent: some View {
        switch selectedPadTab {
        case .summary:
            SummaryPadView(onNavigateToLoad: { selectedPadTab = .load })
        case .load:
            LoadPlacementPadView()
        case .safety:
            SafetyPadView(onNavigateToMaintenance: { selectedPadTab = .maintenance })
        case .maintenance:
            MaintenancePadView()
        case .checklist:
            ChecklistView()
        case .trips:
            NavigationStack {
                TripRecordsListView()
            }
        case .settings:
            SettingsView(onNavigateToSummary: { selectedPadTab = .summary })
        }
    }

    // MARK: - iPhone

    private var phoneTabRoot: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                onNavigateToLoad: { selectedTab = .load },
                onNavigateToSummary: {
                    selectedTab = .load
                    loadWorkflowStep = .summary
                },
                onNavigateToSafety: { selectedTab = .safety },
                onNavigateToCare: { selectedTab = .care },
                onNavigateToMaintenance: { navigateToPhoneMaintenance() },
                onNavigateToTyreSafety: { navigateToPhoneTyreSafety() },
                onNavigateToWarranty: { navigateToPhoneWarranty() },
                onNavigateToIncidents: { navigateToPhoneIncidents() },
                onNavigateToTrips: { navigateToPhoneTrips() }
            )
            .tag(AppTab.home)
            .tabItem { Label("Home", systemImage: "house") }

            LoadView(
                workflowStep: $loadWorkflowStep,
                onNavigateToSettings: { selectedTab = .more }
            )
                .tag(AppTab.load)
                .tabItem { Label("Load", systemImage: "shippingbox") }

            SafetyView(
                onNavigateToMaintenance: { navigateToPhoneMaintenance() },
                onNavigateToIncidents: { navigateToPhoneIncidents() }
            )
                .tag(AppTab.safety)
                .tabItem { Label("Safety", systemImage: "shield") }

            CareView(pendingDestination: $pendingCareDestination)
                .tag(AppTab.care)
                .tabItem { Label("Care", systemImage: "hammer") }

            MoreView(onNavigateToHome: { selectedTab = .home })
                .tag(AppTab.more)
                .tabItem { Label("More", systemImage: "ellipsis") }
        }
    }

    private var setupAlertTitle: String {
        activeProfile?.kind == .motorhome ? "Motorhome setup" : "Caravan setup"
    }

    private var setupAlertMessage: String {
        guard let profile = activeProfile else {
            return "Add a vehicle in Settings for weight calculations. You can still use Load, Safety, and Care first."
        }
        return profile.weightCalculationSetupSummaryMessage
            + " You can still use Load, Safety, and Care before completing Settings."
    }

    private func presentSetupPromptIfNeeded() {
        guard needsSetup, !didPresentSetupPrompt else { return }
        didPresentSetupPrompt = true
        selectedTab = .more
        selectedPadTab = .settings
        showSetupAlert = true
    }

    private func navigateToPhoneMaintenance() {
        selectedTab = .care
        pendingCareDestination = .maintenance
    }

    private func navigateToPhoneTyreSafety() {
        selectedTab = .care
        pendingCareDestination = .tyreSafety
    }

    private func navigateToPhoneWarranty() {
        selectedTab = .care
        pendingCareDestination = .warranty
    }

    private func navigateToPhoneIncidents() {
        selectedTab = .care
        pendingCareDestination = .incidents
    }

    private func navigateToPhoneTrips() {
        selectedTab = .care
        pendingCareDestination = .tripRecords
    }
}

private struct AvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
