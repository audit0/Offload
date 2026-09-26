import AppKit
import Observation
import OffloadCore

/// Разбор Mac одной кнопкой: найти, разложить по действиям, дать человеку поправить, выполнить.
///
/// Ничего не делается без подтверждения. Удаление — только в Корзину и только для того,
/// что пересоздаётся само, и для лишних копий одинаковых файлов (одна копия всегда остаётся
/// и сверяется с удаляемой байт в байт); перенос в сейф — тот же, что в «Освободить место», со сверкой.
/// Решения человека запоминаются: по тому же объекту в следующий раз предлагается то же,
/// а для похожего — то, что человек обычно выбирает (привычки, `HabitModel`).
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
        /// Второй этап — поиск одинаковых файлов. Сколько их всего, заранее неизвестно.
        var duplicates = false
        var files = 0
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
        /// Сколько из отправленного в Корзину — лишние копии одинаковых файлов.
        var duplicates = 0
        /// Что не сделано и почему — каждое отдельной строкой.
        var problems: [String] = []
        var cancelled = false
    }

    private(set) var stage: Stage = .idle
    private(set) var suggestions: [CleanupSuggestion] = []
    /// Выбор человека поверх предложения. Меняется через `setChoice`, чтобы у каждой группы
    /// одинаковых файлов оставалась хотя бы одна копия.
    private(set) var choices: [String: CleanupAction] = [:]
    /// Группы одинаковых файлов в порядке списка: сначала те, где освободится больше.
    private(set) var duplicateGroups: [String] = []
    private(set) var lastRun: DecisionStore.Run?
    /// База решений не открылась: разбор работает, но ничего не запоминает.
    private(set) var storeProblem: String?
    /// Чему Offload научился: самые подкреплённые привычки и по скольким объектам решения
    /// в памяти — столько забудет «Забыть мои решения».
    private(set) var habits: [HabitModel.Prediction] = []
    private(set) var remembered = 0
    private(set) var forgetProblem: String?

    @ObservationIgnored private var store: DecisionStore?
    @ObservationIgnored private var token = CancelToken()
    /// Копии каждой группы и папки из списка, в которых лежат копии: считаются один раз на список.
    @ObservationIgnored private var copiesByGroup: [String: [CleanupSuggestion]] = [:]
    @ObservationIgnored private var containers: [String: CleanupSuggestion] = [:]

    init() {
        do {
            // В демонстрации база в памяти: вымышленные решения не должны попасть в настоящую.
            store = try DecisionStore(url: Demo.isOn ? nil : DecisionStore.defaultURL)
            if Demo.isOn { try store?.record(Demo.decisions()) }
            lastRun = try store?.lastRun()
        } catch {
            storeProblem = error.localizedDescription
        }
    }

    /// Перечитывает, чему научился Offload: при открытии раздела, после разбора и после «Забыть».
    func loadHabits(home: URL) {
        guard let store, let history = try? store.history() else { return }
        habits = HabitModel(history: history, home: home).habits()
        remembered = (try? store.lastDecisions().count) ?? 0
    }

    /// Забывает все решения — и «как в прошлый раз», и привычки. Итоги прошлых разборов остаются.
    func forgetDecisions(home: URL) {
        guard !isBusy else { return }
        do {
            try store?.forgetDecisions()
            forgetProblem = nil
        } catch {
            forgetProblem = error.localizedDescription
        }
        loadHabits(home: home)
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

    func setChoice(_ action: CleanupAction, for suggestion: CleanupSuggestion) {
        choices[suggestion.id] = action
        keepOneCopyEach()
    }

    /// Что станет с объектом при выполнении. Копия, выбранная в Корзину, но лежащая в папке,
    /// которая уезжает в сейф, едет вместе с папкой: удалить её до переноса значило бы
    /// поменять папку, и перенос остановился бы на свежем изменении.
    func effectiveChoice(for suggestion: CleanupSuggestion) -> CleanupAction {
        let chosen = choice(for: suggestion)
        return chosen == .trash && carrier(of: suggestion) != nil ? .keep : chosen
    }

    /// Папка из списка, выбранная в сейф, внутри которой лежит копия.
    func carrier(of suggestion: CleanupSuggestion) -> CleanupSuggestion? {
        guard let container = containers[suggestion.id], choice(for: container) == .safe else { return nil }
        return container
    }

    func items(_ action: CleanupAction) -> [CleanupSuggestion] {
        suggestions.filter { effectiveChoice(for: $0) == action }
    }

    func copies(in group: String) -> [CleanupSuggestion] { copiesByGroup[group] ?? [] }

    /// Что можно выбрать в строке: у последней остающейся копии группы Корзины нет.
    /// Текущий выбор в списке есть всегда — иначе переключатель показал бы пустоту.
    func options(for suggestion: CleanupSuggestion) -> [CleanupAction] {
        guard let group = suggestion.duplicateGroup else { return suggestion.allowed }
        let chosen = choice(for: suggestion)
        let possible = CleanupPlanner.options(for: suggestion, in: copies(in: group), effective: { self.effectiveChoice(for: $0) })
        return suggestion.allowed.filter { possible.contains($0) || $0 == chosen }
    }

    /// Сколько освободится в группе при нынешнем выборе.
    func freedBytes(in group: String) -> Int64 {
        copies(in: group).filter { effectiveChoice(for: $0) == .trash }.reduce(0) { $0 + $1.bytes }
    }

    /// Выбор у папки мог оставить группу без остающейся копии (копия ехала в сейф вместе с папкой) —
    /// тогда первая копия группы снова остаётся.
    private func keepOneCopyEach() {
        for group in duplicateGroups {
            let copies = copies(in: group)
            if let first = copies.first, copies.allSatisfy({ effectiveChoice(for: $0) == .trash }) {
                choices[first.id] = .keep
            }
        }
    }

    private func show(_ found: [CleanupSuggestion]) {
        suggestions = found
        var groups: [String: [CleanupSuggestion]] = [:]
        var order: [String] = []
        var inside: [String: CleanupSuggestion] = [:]
        let folders = found.filter { $0.isDirectory && $0.duplicateGroup == nil }
        for suggestion in found {
            guard let group = suggestion.duplicateGroup else { continue }
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(suggestion)
            if let container = CleanupPlanner.container(of: suggestion, in: folders) { inside[suggestion.id] = container }
        }
        copiesByGroup = groups
        containers = inside
        duplicateGroups = order
    }

    func bytes(_ action: CleanupAction) -> Int64 {
        items(action).reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Поиск

    func scan(app: AppModel) {
        guard !isBusy else { return }
        choices = [:]
        if Demo.isOn {
            show(Demo.cleanupSuggestions())
            stage = .review
            return
        }
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let sources = app.backup.sources.map(\.standardizedFileURL.path)
        let memory = (try? store?.lastDecisions()) ?? [:]
        let habits = (try? store?.history()).map { HabitModel(history: $0, home: rules.home) }
        let store = store
        stage = .scanning(ScanProgress())
        let throttle = Throttle(interval: 0.2)
        let tally = ScanTally()
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [CleanupSuggestion] in
                let regenerable = CleanupPlanner.regenerable(home: rules.home)
                let roots = CleanupPlanner.roots(home: rules.home)
                var seen = Set<String>()
                let urls = (roots.flatMap { SpaceScanner.children(of: $0) }
                            + regenerable.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) })
                    .filter { seen.insert($0.standardizedFileURL.path).inserted }
                await MainActor.run { if !token.isCancelled { self.stage = .scanning(ScanProgress(total: urls.count)) } }
                let planner = CleanupPlanner(home: rules.home, regenerable: regenerable, memory: memory, habits: habits)
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
                guard !token.isCancelled else { return [] }

                // Второй этап — одинаковые файлы. du только что прошёл по тем же папкам,
                // и обход идёт по тёплому кешу файловой системы.
                var measured = tally.snapshot
                measured.duplicates = true
                let shown = measured
                await MainActor.run { if !token.isCancelled { self.stage = .scanning(shown) } }
                let started = Date()
                let result = DuplicateFinder().find(in: roots, rules: rules, known: (try? store?.fingerprints()) ?? [:],
                                                    isCancelled: { token.isCancelled }) { found in
                    guard throttle.ready() else { return }
                    var progress = measured
                    progress.files = found.files
                    progress.current = found.current
                    Task { @MainActor in
                        if case .scanning = self.stage, !token.isCancelled { self.stage = .scanning(progress) }
                    }
                }
                // Только после законченного поиска: отпечатки прочитанных файлов — в базу, а те,
                // которых поиск не коснулся (файла нет или сравнивать его больше не с чем), — забыть.
                if result.completed {
                    try? store?.saveFingerprints(result.fingerprints, at: started)
                    try? store?.forgetFingerprints(seenBefore: started)
                }
                return planner.suggestions(collector.all, duplicates: result.groups)
            }.value
            guard !token.isCancelled else {
                stage = .idle
                return
            }
            show(found)
            stage = .review
        }
    }

    // MARK: - Выполнение

    func run(app: AppModel) {
        guard stage == .review else { return }
        let work = suggestions.map { (item: $0, action: choice(for: $0)) }
        // Решения запоминаются сразу, даже если выполнение потом отменят: выбор человек сделал.
        // Вместе с решением — каким был объект и что предлагалось: на этом учатся привычки.
        // «Оставить» там, где оставить и предлагалось, — не выбор, и такое не записывается.
        do {
            try store?.record(work.map {
                DecisionStore.Decision(path: $0.item.id, action: $0.action, bytes: $0.item.bytes, suggested: $0.item.action,
                                       kind: $0.item.kind, modified: $0.item.modified)
            }.filter(\.isChoice))
        } catch {
            storeProblem = error.localizedDescription
        }
        // Сначала лишние копии: пока ни одна папка не уехала в сейф, каждую есть с чем сверить.
        // Копия внутри папки, которая уезжает в сейф, едет вместе с ней и не удаляется.
        let redundant = work.filter { $0.item.duplicateGroup != nil && effectiveChoice(for: $0.item) == .trash }
            .map { entry in (item: entry.item, action: entry.action, reference: entry.item.duplicateGroup.flatMap { group in
                CleanupPlanner.reference(for: entry.item, in: copies(in: group), effective: { self.effectiveChoice(for: $0) })
            }) }
        let rest = work.filter { $0.action != .keep && !($0.item.duplicateGroup != nil && $0.action == .trash) }
            .map { (item: $0.item, action: $0.action, reference: CleanupSuggestion?.none) }
        let todo = redundant + rest
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let throttle = Throttle()
        let operationID = app.beginOperation { token.cancel() }
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
                case .trash where item.duplicateGroup != nil:
                    guard let reference = entry.reference else {
                        report.problems.append("«\(name)» осталось на месте: не остаётся ни одной копии, с которой его можно сверить.")
                        continue items
                    }
                    if Demo.isOn {
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                        report.duplicates += 1
                        continue items
                    }
                    stage = .running(Progress(index: index + 1, count: todo.count, item: name, phase: "Сверка с копией", fraction: 0))
                    let url = item.url
                    let total = max(item.bytes, 1)
                    let compared = Counter()
                    do {
                        // Сверяется содержимое, а не отпечаток из поиска: файл могли изменить после него.
                        let same = try await Task.detached(priority: .userInitiated) {
                            let same = try DuplicateFinder.sameContent(url, reference.url, isCancelled: { token.isCancelled }) { read in
                                let done = compared.add(Int64(read))
                                guard throttle.ready() else { return }
                                Task { @MainActor in
                                    if case .running(var current) = self.stage, current.item == name {
                                        current.fraction = min(1, Double(done) / Double(total))
                                        self.stage = .running(current)
                                    }
                                }
                            }
                            if same { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                            return same
                        }.value
                        guard same else {
                            report.problems.append("«\(name)» осталось на месте: после поиска оно изменилось и больше не совпадает с «\(reference.url.lastPathComponent)».")
                            continue items
                        }
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                        report.duplicates += 1
                    } catch is CancellationError {
                        report.cancelled = true
                        break items
                    } catch {
                        report.problems.append("«\(name)» не удалось отправить в Корзину: \(error.localizedDescription)")
                    }
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
            loadHabits(home: rules.home)
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
        show([])
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

    var snapshot: CleanupModel.ScanProgress { lock.withLock { progress } }

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
