import OffloadCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var safe = app.safe
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $app.section) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                SafeStatusPanel().padding(10)
            }
        } detail: {
            // GeometryReader: иначе NavigationSplitView на macOS берёт идеальную высоту содержимого
            // (у ScrollView это высота всего списка), вырастает больше окна и уезжает за его край.
            GeometryReader { _ in
                Group {
                    switch app.section ?? .overview {
                    case .overview: OverviewView()
                    case .cleanup: CleanupView()
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
        .tint(Theme.brand)
        // Сменили диск — перечитываем, есть ли на нём сейф и открыт ли он.
        .task(id: app.destinationID) { app.safe.refresh(app: app) }
        // Закрыть сейф не дали открытые в нём файлы — откуда бы ни закрывали: из панели, меню или раздела.
        .alert("Сейф не закрывается", isPresented: $safe.closeBlocked) {
            Button("Закрыть принудительно", role: .destructive) { app.safe.close(app: app, force: true) }
            Button("Оставить открытым", role: .cancel) {}
        } message: {
            Text("В нём открыты файлы в других программах. Закройте их и повторите — или закройте сейф принудительно: несохранённое в этих программах может пропасть.")
        }
        // Журнал нужен не только разделу «Перенесённое»: «Обзор» и «Сейф» по нему видят,
        // что лежит на диске открыто. Поэтому читается сразу и при каждой смене дисков и сейфа.
        .task(id: app.historyVolumes.map(\.id)) { app.history.reload(volumes: app.historyVolumes) }
    }

    /// Сколько перенесённого лежит на дисках — видно, не заходя в раздел. Ноль не показывается.
    private func badge(for section: SidebarSection) -> Int {
        guard section == .history else { return 0 }
        return app.history.records.filter { !$0.restored }.count
    }
}
