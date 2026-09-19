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
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                DestinationFooter().padding(12)
            }
        } detail: {
            // GeometryReader: иначе NavigationSplitView на macOS берёт идеальную высоту содержимого
            // (у ScrollView это высота всего списка), вырастает больше окна и уезжает за его край.
            GeometryReader { _ in
                Group {
                    switch app.section ?? .overview {
                    case .overview: OverviewView()
                    case .space: SpaceView()
                    case .history: HistoryView()
                    case .backup: BackupView()
                    case .docker: DockerView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
