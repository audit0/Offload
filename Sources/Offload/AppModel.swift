import AppKit
import Observation
import OffloadCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, space, history, backup, docker

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .space: return "Что занимает место"
        case .history: return "Перенесённое"
        case .backup: return "Бэкап"
        case .docker: return "Docker"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .space: return "chart.bar.doc.horizontal"
        case .history: return "clock.arrow.circlepath"
        case .backup: return "externaldrive.badge.checkmark"
        case .docker: return "shippingbox"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var section: SidebarSection? = .overview
    private(set) var volumes: [VolumeInfo] = []
    var destinationID: String?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    let rules = SafetyRules()
    let overview = OverviewModel()
    let space = SpaceModel()
    let history = HistoryModel()
    let backup = BackupModel()
    let docker = DockerModel()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var cancellers: [UUID: @Sendable () -> Void] = [:]
    /// Сколько операций прямо сейчас копируют данные: пока они идут, выход из программы
    /// оставил бы на диске незаконченную копию, поэтому он спрашивает подтверждение.
    private(set) var runningOperations = 0

    var destination: VolumeInfo? { volumes.first { $0.id == destinationID } }
    var isBusy: Bool { runningOperations > 0 }

    /// Идентификатор заводится здесь, на каждый запуск свой. Один общий на модель приводил
    /// к тому, что второй запуск не регистрировался вовсе, а конец первого снимал учёт обоих:
    /// счётчик обнулялся посреди копирования, и выход из программы переставал спрашивать.
    func beginOperation(cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        cancellers[id] = cancel
        runningOperations += 1
        return id
    }

    func endOperation(_ id: UUID) {
        guard cancellers.removeValue(forKey: id) != nil else { return }
        runningOperations = max(0, runningOperations - 1)
    }

    func cancelEverything() {
        for cancel in cancellers.values { cancel() }
    }

    init() {
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    /// Список внешних дисков и свободное место на них меняются после каждой операции.
    func refreshVolumes() {
        volumes = Volumes.external()
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
