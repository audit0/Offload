import AppKit
import OffloadCore
import SwiftUI

@main
struct OffloadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    static let repositoryURL = URL(string: "https://github.com/audit0/Offload")!

    var body: some Scene {
        WindowGroup("Offload") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О программе Offload") { AboutPanel.show() }
            }
            // Как «Dismount All» в VeraCrypt: закрыть сейф из любого места одним сочетанием.
            CommandMenu("Сейф") {
                Button("Закрыть сейф") { model.safe.close(app: model) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.safe.isOpen)
                Button("Открыть раздел «Сейф»") { model.section = .safe }
                    .keyboardShortcut("0", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Link("Offload на GitHub", destination: Self.repositoryURL)
                Link("Сообщить о проблеме", destination: Self.repositoryURL.appendingPathComponent("issues"))
            }
        }
    }
}

enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "разработка"
        let credits = NSMutableAttributedString(string: "Разгрузка диска Mac без риска потерять данные.\nОригинал удаляется только после проверенной копии.\n\n")
        credits.append(NSAttributedString(string: "github.com/audit0/Offload", attributes: [.link: OffloadApp.repositoryURL]))
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Offload",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нужно при запуске через `swift run`, без пакета .app.
        NSApp.setActivationPolicy(.regular)
        // Тема одна — светлая, как у «Панели агентов»: чёрно-белый вид при любой теме macOS,
        // в том числе у листов, меню и предупреждений.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate()
        if let directory = ProcessInfo.processInfo.environment["OFFLOAD_SNAPSHOT_DIR"], !directory.isEmpty {
            Task { await Snapshots.run(into: URL(fileURLWithPath: directory, isDirectory: true), delegate: self) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Пока идёт копирование, выход (Cmd+Q, закрытие окна) убил бы фоновую работу на полпути,
    /// и рядом с папкой осталась бы скрытая недокопия «.offload-partial-…» в полный размер.
    /// Поэтому сначала спрашиваем, потом отменяем по-человечески и ждём, пока уберётся мусор.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else {
            closeSafeBeforeQuit()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Сейчас идёт копирование"
        alert.informativeText = "Если выйти, копирование прервётся. Данные не пострадают: оригинал не удаляется, пока копия не сверена, а незаконченная копия будет убрана."
        alert.addButton(withTitle: "Прервать и выйти")
        alert.addButton(withTitle: "Не выходить")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.cancelEverything()
        Task { @MainActor in
            // Отмена проверяется между файлами, поэтому ждём настоящего конца работы,
            // но не бесконечно: через полминуты выходим в любом случае.
            let deadline = Date().addingTimeInterval(30)
            while model.isBusy, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            self.closeSafeBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Выходя, сейф закрываем всегда: оставить его открытым без программы, которая следит
    /// за сном, блокировкой и простоем, значило бы оставить ключ в памяти без присмотра.
    /// Если в нём открыты файлы, спрашиваем, закрыть ли принудительно.
    private func closeSafeBeforeQuit() {
        guard !Demo.isOn, let model, let mount = model.safe.state?.mount else { return }
        do {
            try SecretsVault.detach(mount)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Сейф не закрывается"
            alert.informativeText = "В нём открыты файлы в других программах. Закрыть принудительно? Несохранённое в этих программах может пропасть."
            alert.addButton(withTitle: "Закрыть принудительно")
            alert.addButton(withTitle: "Оставить открытым")
            if alert.runModal() == .alertFirstButtonReturn { try? SecretsVault.detach(mount, force: true) }
        }
    }
}

/// Режим для разработки: `OFFLOAD_SNAPSHOT_DIR=папка Offload.app/Contents/MacOS/Offload`
/// проходит по всем разделам, сохраняет их снимки в PNG и завершает приложение.
/// Снимки делаются средствами самого окна, разрешение «Запись экрана» не нужно.
@MainActor
enum Snapshots {
    static func run(into directory: URL, delegate: AppDelegate) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        for candidate in NSApp.windows {
            let f = candidate.frame
            FileHandle.standardError.write(Data("окно #\(candidate.windowNumber) «\(candidate.title)» \(Int(f.width))×\(Int(f.height)) видимо=\(candidate.isVisible) класс=\(type(of: candidate))\n".utf8))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }), let model = delegate.model else {
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.makeKeyAndOrderFront(nil)
        // Первое программное переключение раздела до окончания начальной раскладки боковой панели теряется.
        try? await Task.sleep(for: .seconds(2))
        let started = Date()
        func log(_ text: String) { FileHandle.standardError.write(Data("[\(Int(Date().timeIntervalSince(started))) с] \(text)\n".utf8)) }
        let wanted = ProcessInfo.processInfo.environment["OFFLOAD_SNAPSHOT_SECTIONS"]?
            .split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) }
        for section in wanted?.isEmpty == false ? wanted! : SidebarSection.allCases {
            log("раздел \(section.rawValue)")
            model.section = section
            try? await Task.sleep(for: .seconds(3))
            await focus(window, model: model, section: section)
            save(window, to: directory.appendingPathComponent("\(section.rawValue)-3s.png"))
            // Разделы с данными наполняются не сразу: размеры папок и Docker — десятки секунд,
            // «Бэкап» ждёт ответа hdiutil про контейнер, и кадр заставал бы его на полпути.
            let extra = section == .space ? 22 : section == .docker ? 17 : section == .backup ? 8 : 0
            if extra > 0 {
                try? await Task.sleep(for: .seconds(extra))
                await focus(window, model: model, section: section)
                save(window, to: directory.appendingPathComponent("\(section.rawValue).png"))
            }
            log("снимок \(section.rawValue)")
        }
        NSApp.terminate(nil)
    }

    /// Снимок собственного окна: composited-кадр из Window Server. Для окон своего процесса
    /// разрешение «Запись экрана» не требуется. Функция берётся через dlsym, потому что
    /// формально помечена устаревшей, а её замена (ScreenCaptureKit) требует разрешения.
    /// Пока окно неактивно, боковой список не принимает программную смену раздела, а при активации
    /// возвращает в модель свой прежний выбор. Перед кадром окно активируется, раздел выставляется заново.
    static func focus(_ window: NSWindow, model: AppModel, section: SidebarSection) async {
        guard model.section != section else { return }
        model.section = section
        try? await Task.sleep(for: .milliseconds(700))
    }

    /// OFFLOAD_SNAPSHOT_DEBUG=1 — вместе со снимком выгрузить в stderr иерархию AppKit-вью с координатами.
    static func dump(_ view: NSView, depth: Int = 0, limit: Int = 7) {
        guard depth <= limit else { return }
        let name = String(describing: type(of: view)).prefix(60)
        let f = view.frame
        let flags = (view.isHidden ? " hidden" : "") + (view.alphaValue < 1 ? " alpha=\(view.alphaValue)" : "")
        FileHandle.standardError.write(Data("\(String(repeating: "  ", count: depth))\(name) [\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))×\(Int(f.height))]\(flags)\n".utf8))
        for child in view.subviews { dump(child, depth: depth + 1, limit: limit) }
    }

    /// Снимок содержимого окна без разрешения «Запись экрана»: слой окна рисуется в собственный
    /// контекст. `CGWindowListCreateImage` для этого не годится — без разрешения он отдаёт пустой
    /// кадр, а разрешение привязано к подписи и слетает при каждой пересборке приложения.
    /// Подложку приходится заливать цветом окна: слой рисует только содержимое, прозрачный фон
    /// в PNG стал бы белым, и светлый текст тёмной темы пропал бы на нём целиком.
    static func save(_ window: NSWindow, to url: URL) {
        if ProcessInfo.processInfo.environment["OFFLOAD_SNAPSHOT_DEBUG"] == "1", let root = window.contentView {
            FileHandle.standardError.write(Data("--- иерархия вью для \(url.lastPathComponent) ---\n".utf8))
            dump(root)
        }
        guard let root = window.contentView, let layer = root.layer else { return }
        root.displayIfNeeded()
        let scale = window.backingScaleFactor
        let width = Int((root.bounds.width * scale).rounded())
        let height = Int((root.bounds.height * scale).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        var background = NSColor.windowBackgroundColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? background
        }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Слой считает начало координат сверху, контекст рисования — снизу.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
