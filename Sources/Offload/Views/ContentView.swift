import OffloadCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $app.section) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                SafeStatusPanel().padding(12)
            }
        } detail: {
            // GeometryReader: иначе NavigationSplitView на macOS берёт идеальную высоту содержимого
            // (у ScrollView это высота всего списка), вырастает больше окна и уезжает за его край.
            GeometryReader { _ in
                Group {
                    switch app.section ?? .overview {
                    case .overview: OverviewView()
                    case .safe: SafeView()
                    case .space: SpaceView()
                    case .history: HistoryView()
                    case .backup: BackupView()
                    case .docker: DockerView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Сменили диск — перечитываем, есть ли на нём сейф и открыт ли он.
        .task(id: app.destinationID) { app.safe.refresh(app: app) }
        // Журнал нужен не только разделу «Перенесённое»: «Обзор» и «Сейф» по нему видят,
        // что лежит на диске открыто. Поэтому читается сразу и при каждой смене дисков и сейфа.
        .task(id: app.historyVolumes.map(\.id)) { app.history.reload(volumes: app.historyVolumes) }
    }
}
