import AppKit
import Observation
import OffloadCore

/// Порядок разделов — это и есть сценарий: посмотреть, что с Mac; завести сейф;
/// освободить место переносом в него; видеть и возвращать перенесённое; бэкапить.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, safe, space, history, backup, docker

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .cleanup: return "Разобрать"
        case .safe: return "Сейф"
        case .space: return "Освободить место"
        case .history: return "Перенесённое"
        case .backup: return "Бэкап"
        case .docker: return "Docker"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .cleanup: return "wand.and.stars"
        case .safe: return "lock.shield"
        case .space: return "chart.bar.doc.horizontal"
        case .history: return "clock.arrow.circlepath"
        case .backup: return "externaldrive.badge.checkmark"
        case .docker: return "shippingbox"
        }
    }
}

/// Куда класть: в сейф (зашифровано) или открытой папкой на диск.
enum StoreMode: String, CaseIterable, Identifiable {
    case safe, open

    var id: Self { self }
    var title: String { self == .safe ? "В сейф" : "Открыто на диск" }
}

@MainActor
@Observable
final class AppModel {
    var section: SidebarSection? = .overview
    /// Все внешние тома, какими их видит система.
    private(set) var mountedVolumes: [VolumeInfo] = []
    /// Внешние диски. Открытый в Finder сейф — тоже том, но не отдельный диск: его здесь нет.
    var volumes: [VolumeInfo] {
        mountedVolumes.filter { !safe.encryptedMounts.contains($0.mountPoint.standardizedFileURL.path) }
    }
    var destinationID: String?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    let rules = SafetyRules()
    let safe = SafeModel()
    let overview = OverviewModel()
    let space = SpaceModel()
    let history = HistoryModel()
    let backup = BackupModel()
    let docker = DockerModel()
    let cleanup = CleanupModel()

    /// Только что подключённый внешний диск: «Обзор» предлагает разобрать Mac одной кнопкой.
    var connectedPrompt: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var cancellers: [UUID: @Sendable () -> Void] = [:]
    /// Сколько операций прямо сейчас копируют данные: пока они идут, выход из программы
    /// оставил бы на диске незаконченную копию, поэтому он спрашивает подтверждение.
    private(set) var runningOperations = 0

    var destination: VolumeInfo? { volumes.first { $0.id == destinationID } }
    var isBusy: Bool { runningOperations > 0 }

    /// По умолчанию — в сейф: на внешнем диске, который можно потерять, открытыми
    /// лежать должны только те данные, для которых человек сам так решил.
    var storeMode: StoreMode = StoreMode(rawValue: UserDefaults.standard.string(forKey: "storeMode") ?? "") ?? .safe {
        didSet { if !Demo.isOn { UserDefaults.standard.set(storeMode.rawValue, forKey: "storeMode") } }
    }

    /// Открытый сейф на выбранном диске как место назначения.
    var safeVolume: VolumeInfo? { safe.volume(host: destination) }

    /// Куда пойдут перенос, бэкап и тома Docker: сейф или сам диск — как выбрано.
    var target: VolumeInfo? { storeMode == .safe ? safeVolume : destination }

    /// Почему класть некуда — одной фразой, с тем, что сделать.
    var targetProblem: String? {
        guard destination != nil else { return "Подключите внешний диск." }
        guard storeMode == .safe, safeVolume == nil else { return nil }
        return safe.exists ? "Сейф закрыт — откройте его паролем." : "На диске нет сейфа — создайте его в разделе «Сейф»."
    }

    /// Где искать журналы переносов: подключённые диски и открытый сейф.
    var historyVolumes: [VolumeInfo] { volumes + [safeVolume].compactMap { $0 } }

    /// Перенесённое, что лежит на выбранном диске открыто: его прочтёт любой, у кого диск.
    var plainRecords: [MoveRecord] {
        guard let host = destination else { return [] }
        if Demo.isOn { return history.records.filter { !$0.isEncrypted && !$0.restored } }
        let prefix = host.mountPoint.path + "/"
        let fm = FileManager.default
        return history.records.filter {
            !$0.isEncrypted && $0.archivedPath.hasPrefix(prefix) && fm.fileExists(atPath: $0.archivedPath)
        }
    }

    /// Идентификатор заводится здесь, на каждый запуск свой. Один общий на модель приводил
    /// к тому, что второй запуск не регистрировался вовсе, а конец первого снимал учёт обоих:
    /// счётчик обнулялся посреди копирования, и выход из программы переставал спрашивать.
    func beginOperation(cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        cancellers[id] = cancel
        runningOperations += 1
        safe.noteUse()
        return id
    }

    func endOperation(_ id: UUID) {
        guard cancellers.removeValue(forKey: id) != nil else { return }
        runningOperations = max(0, runningOperations - 1)
        // Закрытие сейфа, отложенное ради копирования (сон, блокировка экрана, команда), — сейчас.
        if runningOperations == 0 { safe.operationsFinished(app: self) }
    }

    func cancelEverything() {
        for cancel in cancellers.values { cancel() }
    }

    init() {
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        // Сейф — тоже том: его открытие и закрытие приходят сюда же, в том числе если
        // его открыли или закрыли в обход Offload (hdiutil, Дисковая утилита).
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let known = Set(self.volumes.map(\.id))
                    let opening = self.safe.activity != nil
                    Task {
                        // Сначала — какие из томов открытые сейфы: сейф, открытый в Finder, иначе
                        // на миг попал бы в список дисков, а «Обзор» предложил бы его разобрать.
                        await self.safe.reloadEncryptedMounts(app: self)
                        self.refreshVolumes()
                        self.safe.refresh(app: self)
                        // Появился новый диск — не сейф, который сейчас открывается (его том может
                        // называться как угодно, у старых сейфов — «Secrets»), а настоящий внешний.
                        if name == NSWorkspace.didMountNotification, !opening,
                           let added = self.volumes.first(where: { !known.contains($0.id) && $0.name != SecretsVault.safeVolumeName }) {
                            self.connectedPrompt = added.name
                        }
                    }
                }
            })
        }
        safe.startGuards(app: self)
        safe.refresh(app: self)
        Task { await safe.reloadEncryptedMounts(app: self) }
    }

    /// Список внешних дисков и свободное место на них меняются после каждой операции.
    func refreshVolumes() {
        if Demo.isOn {
            mountedVolumes = [Demo.disk]
            destinationID = Demo.disk.id
            hasFullDiskAccess = true
            return
        }
        mountedVolumes = Volumes.external()
        if destination == nil { destinationID = volumes.first?.id }
        hasFullDiskAccess = FullDiskAccess.isGranted
    }
}

/// Флаг отмены, который безопасно читать из фоновой работы.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Пропускает не чаще одного события за интервал, чтобы прогресс не заваливал интерфейс.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) { self.interval = interval }

    func ready() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}

final class Collector<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) { lock.withLock { elements.append(element) } }
    var all: [Element] { lock.withLock { elements } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ value: Int64) -> Int64 { lock.withLock { total += value; return total } }
}

enum FullDiskAccess {
    /// Каталог базы TCC читается только при полном доступе к диску.
    static var isGranted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Application Support/com.apple.TCC")) != nil
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

func relativeToHome(_ path: String, home: URL) -> String {
    path.hasPrefix(home.path + "/") ? "~/" + path.dropFirst(home.path.count + 1) : path
}

/// 1 объект, 3 объекта, 5 объектов.
func pluralRu(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let hundreds = abs(count) % 100
    let tens = hundreds % 10
    if (11...14).contains(hundreds) { return many }
    if tens == 1 { return one }
    if (2...4).contains(tens) { return few }
    return many
}
