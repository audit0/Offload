import OffloadCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var safe = app.safe
        @Bindable var pro = app.pro
        @Bindable var updates = app.updates
        NavigationSplitView {
            // Своя колонка вместо List: выделение у List macOS рисует системным синим,
            // а здесь оно чёрно-белое — светло-серая подложка и жирный текст.
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
            .modifier(SidebarBackground())
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if let release = app.updates.available {
                        UpdateSidebarRow(release: release).padding(.horizontal, 10)
                    }
                    ProSidebarRow().padding(.horizontal, 10)
                    SafeStatusPanel().padding([.horizontal, .bottom], 10)
                }
            }
        } detail: {
            // GeometryReader: иначе NavigationSplitView на macOS берёт идеальную высоту содержимого
            // (у ScrollView это высота всего списка), вырастает больше окна и уезжает за его край.
            GeometryReader { _ in
                Group {
                    switch app.section ?? .overview {
                    case .overview: OverviewView()
                    case .cleanup: CleanupView()
                    case .assistant: AssistantView()
                    case .safe: SafeView()
                    case .space: SpaceView()
                    case .history: HistoryView()
                    case .backup: BackupView()
                    case .icloud: CloudRestoreView()
                    case .docker: DockerView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Всё окно — стекло: размытый рабочий стол под приглушающей дымкой.
        .background {
            WindowGlass().ignoresSafeArea()
            Theme.background.ignoresSafeArea()
        }
        .tint(Theme.brand)
        .glassButtons()
        // Сменили диск — перечитываем, есть ли на нём сейф и открыт ли он.
        .task(id: app.destinationID) { app.safe.refresh(app: app) }
        .sheet(isPresented: $pro.isPresented) { ProSheet() }
        .sheet(isPresented: $updates.isPresented) { UpdateSheet() }
        .alert(tr("Обновления"), isPresented: updateResultShown) {
            Button(tr("Готово"), role: .cancel) {}
        } message: {
            Text(updates.checkResult ?? "")
        }
        // Пробный период считается днями: окно могло простоять открытым со вчера. О новой версии — раз в сутки,
        // если человек это включил.
        .task { app.updates.checkIfDue() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.pro.refresh()
            app.updates.checkIfDue()
        }
        // Закрыть сейф не дали открытые в нём файлы — откуда бы ни закрывали: из панели, меню или раздела.
        .alert(tr("Сейф не закрывается"), isPresented: $safe.closeBlocked) {
            Button(tr("Закрыть принудительно"), role: .destructive) { app.safe.close(app: app, force: true) }
            Button(tr("Оставить открытым"), role: .cancel) {}
        } message: {
            Text(tr("В нём открыты файлы в других программах. Закройте их и повторите — или закройте сейф принудительно: несохранённое в этих программах может пропасть."))
        }
        // Журнал нужен не только разделу «Перенесённое»: «Обзор» и «Сейф» по нему видят,
        // что лежит на диске открыто. Поэтому читается сразу и при каждой смене дисков и сейфа.
        .task(id: app.historyVolumes.map(\.id)) { app.history.reload(volumes: app.historyVolumes) }
    }

    /// Итог проверки обновлений из меню: установлена последняя версия или почему проверить не вышло.
    private var updateResultShown: Binding<Bool> {
        Binding(get: { app.updates.checkResult != nil }, set: { if !$0 { app.updates.checkResult = nil } })
    }

    /// Сколько перенесённого лежит на дисках — видно, не заходя в раздел. Ноль не показывается.
    private func badge(for section: SidebarSection) -> Int {
        guard section == .history else { return 0 }
        return app.history.records.filter { !$0.restored }.count
    }
}

/// Строка боковой колонки: выбранная — на светло-серой подложке и жирным, как чат в Telegram.
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
            .modifier(SidebarSelection(isSelected: isSelected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Фон колонки — светлее страницы, на том же стекле окна.
private struct SidebarBackground: ViewModifier {
    func body(content: Content) -> some View {
        // Колонка — чуть светлее страницы, но тоже стекло: окно просвечивает сквозь неё.
        content.background(Color.white.opacity(0.28))
    }
}

private struct SidebarSelection: ViewModifier {
    let isSelected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        content
            .background(isSelected ? Color.white.opacity(0.62) : hovering ? Color.white.opacity(0.3) : .clear, in: shape)
            .overlay { if isSelected { shape.strokeBorder(Theme.glassEdge, lineWidth: 0.8) } }
    }
}
