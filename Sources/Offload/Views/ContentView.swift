import OffloadCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var safe = app.safe
        NavigationSplitView {
            // Своя колонка вместо List: выделение у List macOS рисует системным синим,
            // а здесь, как в «Панели агентов», — светло-серая подложка и жирный текст.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarRow(section: section, badge: badge(for: section), isSelected: (app.section ?? .overview) == section) {
                        app.section = section
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.soft)
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
            .background(Theme.background)
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

/// Строка боковой колонки, как в «Панели агентов»: выбранная — на светло-серой подложке, жирным.
private struct SidebarRow: View {
    let section: SidebarSection
    let badge: Int
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.faint)
                    .frame(width: 20)
                Text(section.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Theme.line, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background((isSelected ? Theme.line : hovering ? Theme.lineSoft : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
