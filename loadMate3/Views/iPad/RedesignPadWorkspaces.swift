import SwiftUI
import SwiftData

struct SafetyPadView: View {
    var onNavigateToMaintenance: (() -> Void)?

    @State private var showIncidents = false

    var body: some View {
        SafetyView(
            onNavigateToMaintenance: onNavigateToMaintenance,
            onNavigateToIncidents: { showIncidents = true }
        )
        .environment(\.usePadLayout, false)
        .navigationTitle("Safety")
        .sheet(isPresented: $showIncidents) {
            NavigationStack {
                AccidentIncidentsView()
            }
        }
    }
}

enum MaintenancePadTab: String, CaseIterable, Identifiable {
    case maintenance = "Maintenance"
    case tyre = "Tyre Safety"
    case warranty = "Service & warranty"
    case documents = "Documents"

    var id: String { rawValue }

    static func tabs(warrantyAvailable: Bool) -> [MaintenancePadTab] {
        allCases.filter { warrantyAvailable || $0 != .warranty }
    }
}

struct MaintenancePadView: View {
    @Query private var profiles: [VehicleProfile]
    @Query private var appStates: [AppState]

    @State private var tab: MaintenancePadTab = .maintenance

    private var activeProfile: VehicleProfile? {
        VehicleProfileStore.activeProfile(
            profiles: profiles,
            appState: AppStateStore.canonical(from: appStates)
        )
    }

    private var visibleTabs: [MaintenancePadTab] {
        MaintenancePadTab.tabs(warrantyAvailable: WarrantySupport.showsWarrantyFeatures(for: activeProfile))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Maintenance section", selection: $tab) {
                ForEach(visibleTabs) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, PadContentLayout.horizontalGutter)
            .padding(.top, AppScreenMetrics.verticalScreenPadding)
            .padding(.bottom, AppScreenMetrics.controlSpacing)
            .frame(maxWidth: PadContentLayout.workspaceMaxWidth)
            .frame(maxWidth: .infinity)

            Group {
                switch tab {
                case .maintenance:
                    MaintenanceView()
                        .environment(\.usePadLayout, false)
                case .tyre:
                    TyreSafetyView()
                        .environment(\.usePadLayout, false)
                case .warranty:
                    WarrantyView()
                        .environment(\.usePadLayout, false)
                case .documents:
                    DocumentsPadView()
                        .environment(\.usePadLayout, false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(tab.rawValue)
        .onChange(of: activeProfile?.warrantyAvailable) { _, _ in
            if !visibleTabs.contains(tab) {
                tab = .maintenance
            }
        }
        .onAppear {
            if !visibleTabs.contains(tab) {
                tab = .maintenance
            }
        }
    }
}

struct CarePadView: View {
    var body: some View {
        CareView()
            .environment(\.usePadLayout, false)
            .navigationTitle("Care")
    }
}

struct DocumentsPadView: View {
    var body: some View {
        NavigationStack {
            DocumentsView()
        }
    }
}
