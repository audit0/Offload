import AppKit
import Observation
import OffloadCore

/// Разбор Mac одной кнопкой: найти, разложить по действиям, дать человеку поправить, выполнить.
///
/// Ничего не делается без подтверждения. Удаление — только в Корзину и только для того,
/// что пересоздаётся само; перенос в сейф — тот же, что в «Освободить место», со сверкой.
/// Решения человека запоминаются, и в следующий раз предложение начинается с них.
@MainActor
@Observable
final class CleanupModel {
    enum Stage: Equatable {
        case idle
        case scanning(ScanProgress)
        case review
        case running(Progress)
        case done(Report)
    }

    /// Поиск: сколько просмотрено, что сейчас и что уже набралось по действиям.
    struct ScanProgress: Equatable {
        var done = 0
        var total = 0
        var current = ""
        var trashBytes: Int64 = 0
        var safeBytes: Int64 = 0
        var backupCount = 0
    }

    struct Progress: Equatable {
        var index: Int
        var count: Int
        var item: String
        var phase: String
        var fraction: Double
    }

    struct Report: Equatable {
        var trashed = 0
        var trashedBytes: Int64 = 0
        var moved = 0
        var movedBytes: Int64 = 0
        var addedToBackup = 0
        /// Что не сделано и почему — каждое отдельной строкой.
        var problems: [String] = []
        var cancelled = false
    }

    private(set) var stage: Stage = .idle
    private(set) var suggestions: [CleanupSuggestion] = []
    /// Выбор человека поверх предложения.
    var choices: [String: CleanupAction] = [:]
    private(set) var lastRun: DecisionStore.Run?
    /// База решений не открылась: разбор работает, но ничего не запоминает.
    private(set) var storeProblem: String?

    @ObservationIgnored private var store: DecisionStore?
    @ObservationIgnored private var token = CancelToken()

    init() {
        do {
            // В демонстрации база в памяти: вымышленные решения не должны попасть в настоящую.
            store = try DecisionStore(url: Demo.isOn ? nil : DecisionStore.defaultURL)
            lastRun = try store?.lastRun()
        } catch {
            storeProblem = error.localizedDescription
        }
    }

    var isBusy: Bool {
        switch stage {
        case .scanning, .running: return true
        default: return false
        }
    }

    func choice(for suggestion: CleanupSuggestion) -> CleanupAction {
        choices[suggestion.id] ?? suggestion.action
    }

    func items(_ action: CleanupAction) -> [CleanupSuggestion] {
        suggestions.filter { choice(for: $0) == action }
    }

    func bytes(_ action: CleanupAction) -> Int64 {
        items(action).reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Поиск

    func scan(app: AppModel) {
        guard !isBusy else { return }
        choices = [:]
        if Demo.isOn {
            suggestions = Demo.cleanupSuggestions()
            stage = .review
            return
        }
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let sources = app.backup.sources.map(\.standardizedFileURL.path)
        let memory = (try? store?.lastDecisions()) ?? [:]
        stage = .scanning(ScanProgress())
        let throttle = Throttle(interval: 0.2)
        let tally = ScanTally()
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [CleanupSuggestion] in
                let regenerable = CleanupPlanner.regenerable(home: rules.home)
                var seen = Set<String>()
                let urls = (CleanupPlanner.roots(home: rules.home).flatMap { SpaceScanner.children(of: $0) }
                            + regenerable.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) })
                    .filter { seen.insert($0.standardizedFileURL.path).inserted }
                await MainActor.run { if !token.isCancelled { self.stage = .scanning(ScanProgress(total: urls.count)) } }
                let planner = CleanupPlanner(regenerable: regenerable, memory: memory)
                let collector = Collector<CleanupObservation>()
                await SpaceScanner.scan(urls, rules: rules, isCancelled: { token.isCancelled }) { item in
                    let path = item.url.standardizedFileURL.path
                    let observation = CleanupObservation(
                        url: item.url, bytes: item.bytes, modified: item.modified, isDirectory: item.isDirectory,
                        verdict: item.verdict,
                        isProject: item.isDirectory
                            && FileManager.default.fileExists(atPath: item.url.appendingPathComponent(".git").path),
                        inBackup: sources.contains { path == $0 || path.hasPrefix($0 + "/") },
                        // `hdiutil isencrypted` отвечает без пароля и окон не открывает (в отличие от imageinfo).
                        isEncryptedImage: !item.isDirectory && item.url.pathExtension.lowercased() == "dmg"
                            && SecretsVault.encryptionInfo(of: item.url)?.encrypted == true)
                    collector.append(observation)
                    // Промежуточный итог — по тем же правилам, что и список: видно, что поиск чего-то стоит.
                    var progress = tally.add(planner.suggest(observation), counted: planner.isWorthShowing)
                    guard throttle.ready() else { return }
                    progress.total = urls.count
                    progress.current = item.url.lastPathComponent
                    Task { @MainActor in
                        if case .scanning = self.stage, !token.isCancelled { self.stage = .scanning(progress) }
                    }
                }
                return planner.suggestions(collector.all)
            }.value
            guard !token.isCancelled else {
                stage = .idle
                return
            }
            suggestions = found
            stage = .review
        }
    }

    // MARK: - Выполнение

    func run(app: AppModel) {
        guard stage == .review else { return }
        let work = suggestions.map { (item: $0, action: choice(for: $0)) }
        // Решения запоминаются сразу, даже если выполнение потом отменят: выбор человек сделал.
        do {
            try store?.record(work.map { (path: $0.item.id, action: $0.action, bytes: $0.item.bytes) })
        } catch {
            storeProblem = error.localizedDescription
        }
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let throttle = Throttle()
        let operationID = app.beginOperation { token.cancel() }
        let todo = work.filter { $0.action != .keep }
        Task {
            var report = Report()
            items: for (index, entry) in todo.enumerated() {
                if token.isCancelled {
                    report.cancelled = true
                    break
                }
                let item = entry.item
                let name = item.url.lastPathComponent
                stage = .running(Progress(index: index + 1, count: todo.count, item: name,
                                          phase: Self.phase(entry.action), fraction: 0))
                switch entry.action {
                case .keep:
                    break
                case .backup:
                    // Сравниваем пути, а не URL: «папка» и «папка/» — одно и то же.
                    let path = item.url.standardizedFileURL.path
                    if !app.backup.sources.contains(where: { $0.standardizedFileURL.path == path }) {
                        app.backup.sources.append(item.url)
                    }
                    report.addedToBackup += 1
                case .trash:
                    if Demo.isOn {
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                        continue items
                    }
                    let url = item.url
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        }.value
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                    } catch {
                        report.problems.append("«\(name)» не удалось отправить в Корзину: \(error.localizedDescription)")
                    }
                case .safe:
                    guard let volume = app.safeVolume else {
                        report.problems.append("«\(name)»: сейф закрыт — осталось на месте.")
                        continue items
                    }
                    if Demo.isOn {
                        report.moved += 1
                        report.movedBytes += item.bytes
                        continue items
                    }
                    let source = item.url
                    let shown = Set(item.cautions)
                    let plan = await Task.detached(priority: .userInitiated) {
                        SafeMover(rules: rules).plan(source: source, volume: volume, isCancelled: { token.isCancelled })
                    }.value
                    if token.isCancelled {
                        report.cancelled = true
                        break items
                    }
                    guard plan.canProceed else {
                        let reason = (plan.verdict.isBlocked ? plan.verdict.notes : plan.check.blockers).first ?? "перенос невозможен"
                        report.problems.append("«\(name)»: \(reason)")
                        continue items
                    }
                    // Оговорки, которых человек не видел, когда выбирал «в сейф» (например, что папку
                    // меняли вчера), — повод спросить отдельно, а не перенести молча.
                    if case .caution(let notes) = plan.verdict, let unseen = notes.first(where: { !shown.contains($0) }) {
                        report.problems.append("«\(name)» осталось на месте: \(unseen) Перенесите вручную в «Освободить место», если уверены.")
                        continue items
                    }
                    do {
                        let record = try await Task.detached(priority: .userInitiated) {
                            try SafeMover(rules: rules).execute(plan, deleteOriginal: true, acceptCautions: true,
                                                                isCancelled: { token.isCancelled }) { progress in
                                guard throttle.ready() else { return }
                                Task { @MainActor in
                                    if case .running(var current) = self.stage, current.item == name {
                                        current.phase = progress.phase.rawValue
                                        current.fraction = progress.fraction
                                        self.stage = .running(current)
                                    }
                                }
                            }
                        }.value
                        report.moved += 1
                        report.movedBytes += record.bytes
                    } catch is CancellationError {
                        report.cancelled = true
                        break items
                    } catch {
                        report.problems.append("«\(name)»: \(error.localizedDescription)")
                    }
                }
            }
            let run = DecisionStore.Run(trashedBytes: report.trashedBytes, movedBytes: report.movedBytes,
                                        addedToBackup: report.addedToBackup, failures: report.problems.count)
            try? store?.recordRun(run)
            lastRun = run
            stage = .done(report)
            app.endOperation(operationID)
            app.history.reload(volumes: app.historyVolumes)
            app.space.invalidateAll()
            app.refreshVolumes()
        }
    }

    func cancel() { token.cancel() }

    /// К началу: после отчёта или чтобы бросить разбор, не выполняя.
    func reset() {
        guard !isBusy else { return }
        suggestions = []
        choices = [:]
        stage = .idle
    }

    private static func phase(_ action: CleanupAction) -> String {
        switch action {
        case .trash: return "В Корзину"
        case .safe: return "Подготовка"
        case .backup: return "В бэкап"
        case .keep: return ""
        }
    }
}

/// Промежуточный итог поиска: пополняется из параллельных замеров, поэтому под замком.
final class ScanTally: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = CleanupModel.ScanProgress()

    func add(_ suggestion: CleanupSuggestion, counted: (CleanupSuggestion) -> Bool) -> CleanupModel.ScanProgress {
        lock.withLock {
            progress.done += 1
            if counted(suggestion) {
                switch suggestion.action {
                case .trash: progress.trashBytes += suggestion.bytes
                case .safe: progress.safeBytes += suggestion.bytes
                case .backup: progress.backupCount += 1
                case .keep: break
                }
            }
            return progress
        }
    }
}
