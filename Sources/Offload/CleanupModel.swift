import AppKit
import Observation
import OffloadCore

/// Разбор Mac одной кнопкой — по образцу Smart Care в CleanMyMac: «Начать» → плитки → «Выполнить».
///
/// Сразу отмечено только то, что программы создадут заново (мусор), и то, что ничего не удаляет
/// (проекты — в список бэкапа). Личное — крупное и старое, лишние копии, установщики — Offload
/// находит и объясняет, а отмечаете вы. Ваш выбор запоминается: тот же объект в следующий раз
/// будет отмечен так же, а похожее — так, как вы обычно решаете (привычки, `HabitModel`).
///
/// Удаление — только в Корзину, и после разбора всё ушедшее туда можно вернуть одной кнопкой
/// или удалить насовсем, чтобы место освободилось сразу. Перенос в сейф — тот же, что
/// в «Освободить место», со сверкой; лишняя копия перед удалением сверяется с остающейся байт в байт.
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

    /// Поиск: сколько просмотрено, что сейчас и что уже нашлось по плиткам.
    struct ScanProgress: Equatable {
        var done = 0
        var total = 0
        var current = ""
        /// Сколько нашлось по плиткам: байты, у проектов — штуки.
        var found: [CleanupModule: Int64] = [:]
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
        var module: CleanupModule?
    }

    /// Что ушло в Корзину в этот раз: откуда и где лежит теперь.
    struct TrashedItem: Equatable, Sendable {
        var original: URL
        var inTrash: URL
        var bytes: Int64
    }

    struct Report: Equatable {
        var trashed = 0
        var trashedBytes: Int64 = 0
        var moved = 0
        var movedBytes: Int64 = 0
        var addedToBackup = 0
        /// Сколько из ушедшего в Корзину — лишние копии одинаковых файлов.
        var duplicates = 0
        var duplicateBytes: Int64 = 0
        /// Что не сделано и почему — каждое отдельной строкой.
        var problems: [String] = []
        var cancelled = false
        /// Свободно на диске Mac до разбора и сейчас: столько освободилось на самом деле.
        var freeBefore: Int64?
        var freeNow: Int64?
        /// То, что можно вернуть из Корзины или удалить насовсем.
        var trashedItems: [TrashedItem] = []
        var restored = 0
        var erased = 0
        var erasedBytes: Int64 = 0

        /// Сколько освободилось на диске Mac: по замеру, а не по сумме размеров.
        var freed: Int64? {
            guard let freeBefore, let freeNow else { return nil }
            return freeNow - freeBefore
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var suggestions: [CleanupSuggestion] = []
    /// Выбор человека поверх того, что отмечено сразу. Меняется через `setChecked`, чтобы
    /// у каждой группы одинаковых файлов оставалась хотя бы одна копия.
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
    /// Что человек просил больше не предлагать.
    private(set) var ignored: [String] = []
    private(set) var ignoreProblem: String?
    /// Что делается с ушедшим в Корзину после разбора («Возвращаю…»): пока не nil, кнопки заблокированы.
    private(set) var finishing: String?

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
            ignored = try store?.ignoredPaths() ?? []
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

    /// Забывает все решения — и «как в прошлый раз», и привычки. Итоги прошлых разборов
    /// и то, что вы просили не предлагать, остаются.
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
        default: return finishing != nil
        }
    }

    // MARK: - Выбор

    func choice(for suggestion: CleanupSuggestion) -> CleanupAction {
        choices[suggestion.id] ?? suggestion.defaultChoice
    }

    /// Отмечен ли объект: с ним что-то произойдёт при выполнении.
    func isChecked(_ suggestion: CleanupSuggestion) -> Bool { choice(for: suggestion) != .keep }

    /// Можно ли отметить: действие плитки разрешено, а у копии — если останется другая.
    func canCheck(_ suggestion: CleanupSuggestion) -> Bool {
        guard let action = suggestion.module?.action else { return false }
        return options(for: suggestion).contains(action)
    }

    func setChecked(_ checked: Bool, for suggestion: CleanupSuggestion) {
        guard let action = suggestion.module?.action else { return }
        if checked, !canCheck(suggestion) { return }
        choices[suggestion.id] = checked ? action : .keep
        keepOneCopyEach()
    }

    /// Отметить или снять всю плитку. У одинаковых файлов «всё» — это все лишние копии:
    /// первая копия группы — та, что остаётся, — не отмечается.
    func setChecked(_ checked: Bool, module: CleanupModule) {
        for suggestion in items(module) {
            if checked {
                guard suggestion.allowed.contains(module.action) else { continue }
                if let group = suggestion.duplicateGroup, copies(in: group).first?.id == suggestion.id { continue }
            }
            choices[suggestion.id] = checked ? module.action : .keep
        }
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

    /// Всё, что показано в плитке.
    func items(_ module: CleanupModule) -> [CleanupSuggestion] {
        suggestions.filter { $0.module == module }
    }

    /// Что в плитке отмечено и будет сделано.
    func selected(_ module: CleanupModule) -> [CleanupSuggestion] {
        items(module).filter { effectiveChoice(for: $0) == module.action }
    }

    func bytes(_ list: [CleanupSuggestion]) -> Int64 { list.reduce(0) { $0 + $1.bytes } }

    /// Сколько освободится на Mac из отмеченного: удаляемое и то, что уезжает в сейф.
    var selectedBytes: Int64 {
        CleanupModule.allCases.filter { $0.action != .backup }.reduce(0) { $0 + bytes(selected($1)) }
    }

    var hasSelection: Bool { CleanupModule.allCases.contains { !selected($0).isEmpty } }

    func copies(in group: String) -> [CleanupSuggestion] { copiesByGroup[group] ?? [] }

    /// Что можно выбрать для объекта: у последней остающейся копии группы Корзины нет.
    func options(for suggestion: CleanupSuggestion) -> [CleanupAction] {
        guard let group = suggestion.duplicateGroup else { return suggestion.allowed }
        return CleanupPlanner.options(for: suggestion, in: copies(in: group), effective: { self.effectiveChoice(for: $0) })
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

    /// Раскладывает найденное: группы одинаковых файлов, папки, в которых лежат копии.
    /// Группа, от которой осталась одна копия (остальные просили не предлагать), не показывается.
    private func show(_ found: [CleanupSuggestion]) {
        var groups: [String: [CleanupSuggestion]] = [:]
        for suggestion in found {
            if let group = suggestion.duplicateGroup { groups[group, default: []].append(suggestion) }
        }
        let lonely = Set(groups.filter { $0.value.count < 2 }.keys)
        let list = found.filter { $0.duplicateGroup.map { !lonely.contains($0) } ?? true }
        suggestions = list
        var order: [String] = []
        var inside: [String: CleanupSuggestion] = [:]
        let folders = list.filter { $0.isDirectory && $0.duplicateGroup == nil }
        for suggestion in list {
            guard let group = suggestion.duplicateGroup else { continue }
            if !order.contains(group) { order.append(group) }
            if let container = CleanupPlanner.container(of: suggestion, in: folders) { inside[suggestion.id] = container }
        }
        copiesByGroup = groups.filter { !lonely.contains($0.key) }
        containers = inside
        duplicateGroups = order
        choices = choices.filter { id, _ in list.contains { $0.id == id } }
        keepOneCopyEach()
    }

    // MARK: - Не предлагать

    /// Больше не предлагать объект (папку — вместе со всем, что внутри). Из нынешнего списка он уходит сразу.
    func ignore(_ suggestion: CleanupSuggestion) {
        let path = suggestion.id
        do {
            try store?.ignore(path)
            ignoreProblem = nil
        } catch {
            ignoreProblem = error.localizedDescription
            return
        }
        ignored = (try? store?.ignoredPaths()) ?? ignored
        show(suggestions.filter { $0.id != path && !$0.id.hasPrefix(path + "/") })
    }

    /// Снова предлагать — со следующего разбора.
    func unignore(_ path: String) {
        do {
            try store?.unignore(path)
            ignoreProblem = nil
        } catch {
            ignoreProblem = error.localizedDescription
        }
        ignored = (try? store?.ignoredPaths()) ?? ignored
    }

    // MARK: - Поиск

    func scan(app: AppModel) {
        guard !isBusy else { return }
        choices = [:]
        let rules = app.rules
        let memory = (try? store?.lastDecisions()) ?? [:]
        let habits = (try? store?.history()).map { HabitModel(history: $0, home: rules.home) }
        let ignored = Set((try? store?.ignoredPaths()) ?? [])
        if Demo.isOn {
            show(Demo.cleanupSuggestions(memory: memory, habits: habits))
            stage = .review
            return
        }
        let token = CancelToken()
        self.token = token
        let sources = app.backup.sources.map(\.standardizedFileURL.path)
        // Кеш открытой программы сам не отмечается: удалять его на ходу не стоит.
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { running[id] = app.localizedName ?? id }
        }
        let busy = CleanupPlanner.busy(home: rules.home, running: running)
        let store = store
        stage = .scanning(ScanProgress())
        let throttle = Throttle(interval: 0.2)
        let tally = ScanTally()
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [CleanupSuggestion] in
                let regenerable = CleanupPlanner.regenerable(home: rules.home)
                let roots = CleanupPlanner.roots(home: rules.home)
                // Подключённый образ `isencrypted` не читает — про такие отвечает `hdiutil info`.
                let attached = SecretsVault.attachedImages()
                var seen = Set<String>()
                let urls = (roots.flatMap { SpaceScanner.children(of: $0) }
                            + regenerable.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) })
                    .filter { seen.insert($0.standardizedFileURL.path).inserted }
                await MainActor.run { if !token.isCancelled { self.stage = .scanning(ScanProgress(total: urls.count)) } }
                let planner = CleanupPlanner(home: rules.home, regenerable: regenerable, memory: memory, habits: habits,
                                             busy: busy, ignored: ignored)
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
                            && SecretsVault.isEncryptedImage(item.url, attached: attached))
                    collector.append(observation)
                    // Промежуточный итог — по тем же правилам, что и плитки: видно, что поиск чего-то стоит.
                    var progress = planner.isIgnored(path) ? tally.skip() : tally.add(planner.suggest(observation), counted: planner.isWorthShowing)
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

    /// `skippingSafe` — выполнить остальное, а отмеченное для сейфа оставить на месте:
    /// сейф не открыт, а человек не хочет открывать его сейчас.
    func run(app: AppModel, skippingSafe: Bool = false) {
        guard stage == .review else { return }
        // Отложенное ради закрытого сейфа — не решение «оставить», и запоминать его так нельзя.
        let skipped = skippingSafe ? Set(selected(.safe).map(\.id)) : []
        if skippingSafe {
            for id in skipped { choices[id] = .keep }
            keepOneCopyEach()
        }
        let work = suggestions.map { (item: $0, action: choice(for: $0)) }
        // Решения запоминаются сразу, даже если выполнение потом отменят: выбор человек сделал.
        // Вместе с решением — каким был объект и что было отмечено: на этом учатся привычки.
        // Не тронутое человеком неотмеченное — не выбор, и такое не записывается: молчание не учит.
        do {
            try store?.record(work.filter { !skipped.contains($0.item.id) }.map {
                DecisionStore.Decision(path: $0.item.id, action: $0.action, bytes: $0.item.bytes, suggested: $0.item.defaultChoice,
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
        let rest = work.filter { $0.action != .keep && $0.item.duplicateGroup == nil }
            .map { (item: $0.item, action: $0.action, reference: CleanupSuggestion?.none) }
        let todo = redundant + rest
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let throttle = Throttle()
        let operationID = app.beginOperation { token.cancel() }
        Task {
            var report = Report()
            report.freeBefore = await Self.freeSpace(home: rules.home)
            items: for (index, entry) in todo.enumerated() {
                if token.isCancelled {
                    report.cancelled = true
                    break
                }
                let item = entry.item
                let name = item.url.lastPathComponent
                stage = .running(Progress(index: index + 1, count: todo.count, item: name,
                                          phase: Self.phase(entry.action), fraction: 0, module: item.module))
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
                        report.duplicateBytes += item.bytes
                        continue items
                    }
                    stage = .running(Progress(index: index + 1, count: todo.count, item: name, phase: "Сверка с копией",
                                              fraction: 0, module: item.module))
                    let url = item.url
                    let total = max(item.bytes, 1)
                    let compared = Counter()
                    do {
                        // Сверяется содержимое, а не отпечаток из поиска: файл могли изменить после него.
                        let trashedAt = try await Task.detached(priority: .userInitiated) { () -> URL?? in
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
                            guard same else { return .none }
                            return .some(try Self.trash(url))
                        }.value
                        guard let trashedAt else {
                            report.problems.append("«\(name)» осталось на месте: после поиска оно изменилось и больше не совпадает с «\(reference.url.lastPathComponent)».")
                            continue items
                        }
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                        report.duplicates += 1
                        report.duplicateBytes += item.bytes
                        if let trashedAt { report.trashedItems.append(TrashedItem(original: url, inTrash: trashedAt, bytes: item.bytes)) }
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
                        let trashedAt = try await Task.detached(priority: .userInitiated) { try Self.trash(url) }.value
                        report.trashed += 1
                        report.trashedBytes += item.bytes
                        if let trashedAt { report.trashedItems.append(TrashedItem(original: url, inTrash: trashedAt, bytes: item.bytes)) }
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
                    // Оговорки, которых человек не видел, когда отмечал «в сейф» (например, что папку
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
            report.freeNow = await Self.freeSpace(home: rules.home)
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

    /// В Корзину; ответ — где объект лежит теперь (nil, если macOS не сказала).
    nonisolated private static func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Сколько свободно на диске Mac — с учётом того, что macOS освободит сама (снимки, кеши).
    nonisolated static func freeSpace(home: URL) async -> Int64? {
        // В демонстрации диск не замеряется: снимок не должен показывать настоящий Mac.
        guard !Demo.isOn else { return nil }
        return await Task.detached(priority: .utility) { () -> Int64? in
            #if os(macOS)
            return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            #else
            return (try? FileManager.default.attributesOfFileSystem(forPath: home.path))?[.systemFreeSize] as? Int64
            #endif
        }.value
    }

    // MARK: - После выполнения: вернуть или удалить насовсем

    /// Возвращает из Корзины всё, что туда отправил этот разбор, на прежние места.
    /// Для вернутого запоминается «оставить»: в следующий раз оно не будет отмечено.
    func restoreTrashed(app: AppModel) {
        guard case .done(var report) = stage, finishing == nil, !report.trashedItems.isEmpty else { return }
        finishing = "Возвращаю из Корзины…"
        let items = report.trashedItems
        let home = app.rules.home
        Task {
            let (back, problems) = await Task.detached(priority: .userInitiated) { () -> ([TrashedItem], [String]) in
                let fm = FileManager.default
                var back: [TrashedItem] = []
                var problems: [String] = []
                for item in items {
                    let name = item.original.lastPathComponent
                    guard fm.fileExists(atPath: item.inTrash.path) else {
                        problems.append("«\(name)»: в Корзине его уже нет.")
                        continue
                    }
                    guard !fm.fileExists(atPath: item.original.path) else {
                        problems.append("«\(name)»: на прежнем месте уже есть файл с таким именем — оставил в Корзине.")
                        continue
                    }
                    do {
                        try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: item.inTrash, to: item.original)
                        back.append(item)
                    } catch {
                        problems.append("«\(name)»: \(error.localizedDescription)")
                    }
                }
                return (back, problems)
            }.value
            try? store?.record(back.map {
                DecisionStore.Decision(path: $0.original.path, action: .keep, bytes: $0.bytes, suggested: .trash)
            })
            let returned = Set(back.map(\.inTrash))
            report.trashedItems.removeAll { returned.contains($0.inTrash) }
            report.restored += back.count
            report.problems += problems
            report.freeNow = await Self.freeSpace(home: home)
            finishing = nil
            stage = .done(report)
            loadHabits(home: home)
            app.space.invalidateAll()
        }
    }

    /// Удаляет насовсем из Корзины ровно то, что туда отправил этот разбор: место освобождается сразу.
    /// Остальное в Корзине не трогается.
    func eraseTrashed(app: AppModel) {
        guard case .done(var report) = stage, finishing == nil, !report.trashedItems.isEmpty else { return }
        finishing = "Удаляю из Корзины…"
        let items = report.trashedItems
        let home = app.rules.home
        Task {
            let (gone, problems) = await Task.detached(priority: .userInitiated) { () -> ([TrashedItem], [String]) in
                var gone: [TrashedItem] = []
                var problems: [String] = []
                for item in items {
                    do {
                        if FileManager.default.fileExists(atPath: item.inTrash.path) {
                            try FileManager.default.removeItem(at: item.inTrash)
                        }
                        gone.append(item)
                    } catch {
                        problems.append("«\(item.original.lastPathComponent)»: \(error.localizedDescription)")
                    }
                }
                return (gone, problems)
            }.value
            let erased = Set(gone.map(\.inTrash))
            report.trashedItems.removeAll { erased.contains($0.inTrash) }
            report.erased += gone.count
            report.erasedBytes += gone.reduce(0) { $0 + $1.bytes }
            report.problems += problems
            report.freeNow = await Self.freeSpace(home: home)
            finishing = nil
            stage = .done(report)
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
            if let module = suggestion.module, counted(suggestion) {
                progress.found[module, default: 0] += module == .projects ? 1 : suggestion.bytes
            }
            return progress
        }
    }

    /// Просмотрено, но человек просил это не предлагать.
    func skip() -> CleanupModel.ScanProgress {
        lock.withLock {
            progress.done += 1
            return progress
        }
    }
}
