import AppKit
import Observation
import OffloadCore

/// Разбор Mac: поиск → вопросы → ответы. Человек не выбирает по файлам и не ходит по папкам:
/// Offload сам раскладывает найденное по вопросам («Удалить мусор — 12 ГБ?», «Очистить Docker?»,
/// «Удалить машину «Windows 11»?»), а на каждый отвечают «да» или «не сейчас». Сделанное по «да»
/// видно сразу у вопроса (`CleanupQuestions`).
///
/// Удаление — только в Корзину (образы Docker удаляет сам Docker), и ушедшее туда можно вернуть
/// у своего вопроса или удалить насовсем в конце, чтобы место освободилось сразу. Перенос в сейф —
/// тот же, что в «Освободить место», со сверкой; лишняя копия перед удалением сверяется
/// с остающейся байт в байт.
@MainActor
@Observable
final class CleanupModel {
    enum Stage: Equatable {
        case idle
        case scanning(ScanProgress)
        /// Найденное разложено по вопросам: человек отвечает, Offload делает.
        case review
    }

    /// Поиск: сколько просмотрено, что сейчас и что уже нашлось по видам.
    struct ScanProgress: Equatable {
        var done = 0
        var total = 0
        var current = ""
        /// Сколько нашлось по видам: байты, у проектов — штуки.
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
    }

    /// Что ушло в Корзину в этот раз: откуда и где лежит теперь.
    struct TrashedItem: Equatable, Sendable {
        var original: URL
        var inTrash: URL
        var bytes: Int64
        /// Какой это файл (см. `FileIdentity`). Вернуть или удалить насовсем можно, только если
        /// по пути в Корзине лежит он же, а не другой, выброшенный туда с тем же именем.
        var identity: FileIdentity?

        /// По пути в Корзине лежит то самое, что туда отправил разбор.
        var isStillInTrash: Bool { identity != nil && FileIdentity.of(inTrash) == identity }
    }

    /// Что сделано по одному вопросу.
    struct Outcome: Equatable {
        /// Сколько объектов сделано.
        var done = 0
        var bytes: Int64 = 0
        /// Сколько из сделанного — лишние копии, сверенные с остающейся.
        var duplicates = 0
        /// То, что можно вернуть из Корзины или удалить насовсем.
        var trashedItems: [TrashedItem] = []
        var restored = 0
        /// Что не сделано и почему — каждое отдельной строкой.
        var problems: [String] = []
        var cancelled = false
    }

    /// Где вопрос сейчас.
    enum Answer: Equatable {
        case asking
        case queued
        case running(Progress)
        case done(Outcome)
        case declined
    }

    private(set) var stage: Stage = .idle
    private(set) var questions: [CleanupQuestion] = []
    private(set) var answers: [CleanupQuestion.Kind: Answer] = [:]
    /// Почему «да» пока не выполнено (например, открыт UTM) — видно под вопросом.
    private(set) var hints: [CleanupQuestion.Kind: String] = [:]
    /// Docker стоит, но не запущен: столько занимает его диск, а что в нём можно убрать, не узнать.
    private(set) var dockerIdle: Int64?
    /// Свободно на Mac перед первым «да» и после последнего сделанного — по замеру, а не по сумме размеров.
    private(set) var freeBefore: Int64?
    private(set) var freeNow: Int64?
    /// Удалено насовсем из Корзины в конце разбора.
    private(set) var erased = 0
    private(set) var erasedBytes: Int64 = 0
    /// Что не получилось у «Вернуть» и «Удалить насовсем».
    private(set) var trashProblems: [String] = []
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
    /// Что делается с ушедшим в Корзину («Возвращаю…»): пока не nil, кнопки заблокированы.
    private(set) var finishing: String?

    @ObservationIgnored private var store: DecisionStore?
    @ObservationIgnored private var scanToken = CancelToken()
    @ObservationIgnored private var workToken = CancelToken()
    /// Вопросы, на которые ответили «да», по очереди: диск работает над одним.
    @ObservationIgnored private var queue: [CleanupQuestion.Kind] = []
    @ObservationIgnored private var working = false
    /// Всё найденное: из него вопросы собираются заново, когда человек просит что-то не предлагать.
    @ObservationIgnored private var suggestions: [CleanupSuggestion] = []
    @ObservationIgnored private var docker: DockerUsage?
    @ObservationIgnored private var machines: [UTMMachine] = []
    @ObservationIgnored private var keptMachines: Set<String> = []
    @ObservationIgnored private var runRecorded = false

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
        if case .scanning = stage { return true }
        return working || finishing != nil
    }

    // MARK: - Вопросы и ответы

    func question(_ kind: CleanupQuestion.Kind) -> CleanupQuestion? { questions.first { $0.kind == kind } }

    func answer(for kind: CleanupQuestion.Kind) -> Answer { answers[kind] ?? .asking }

    /// На что ещё не ответили.
    var asking: [CleanupQuestion] { questions.filter { answer(for: $0.kind) == .asking } }

    /// Сколько освободится, если на всё неотвеченное сказать «да».
    var pendingBytes: Int64 { asking.reduce(0) { $0 + $1.bytes } }

    /// Всё ушедшее в Корзину в этом разборе.
    var trashedItems: [TrashedItem] {
        questions.flatMap { question -> [TrashedItem] in
            if case .done(let outcome) = answer(for: question.kind) { return outcome.trashedItems }
            return []
        }
    }

    /// По «да» что-нибудь уже сделано.
    var hasDone: Bool {
        questions.contains { if case .done = answer(for: $0.kind) { return true } else { return false } }
    }

    /// На всё ответили, и ничего не делается.
    var isSettled: Bool {
        !working && questions.allSatisfy {
            switch answer(for: $0.kind) {
            case .done, .declined: return true
            default: return false
            }
        }
    }

    /// Освободилось на Mac — по замеру свободного места.
    var freed: Int64? {
        guard let freeBefore, let freeNow else { return nil }
        return freeNow - freeBefore
    }

    /// «Да» на вопрос о сейфе требует открытого сейфа: сначала спросить пароль.
    func needsSafe(_ kind: CleanupQuestion.Kind, app: AppModel) -> Bool {
        kind == .module(.safe) && app.safeVolume == nil && !Demo.isOn
    }

    /// Ответ на вопрос. «Да» ставит его в очередь, и он выполняется, как только дойдёт черёд;
    /// «не сейчас» ничего не запоминает — в следующий раз спрошу снова. Кроме машины: решили
    /// оставить — больше не спрашиваю.
    func answer(_ kind: CleanupQuestion.Kind, yes: Bool, app: AppModel) {
        guard stage == .review, let question = question(kind), answer(for: kind) == .asking else { return }
        hints[kind] = nil
        guard yes else {
            answers[kind] = .declined
            if case .machine(let path) = kind, let machine = question.machine {
                record([DecisionStore.Decision(path: path, action: .keep, bytes: machine.bytes, suggested: .trash,
                                               kind: .folder, modified: machine.modified)])
            }
            settle(app: app)
            return
        }
        guard !needsSafe(kind, app: app) else { return }
        answers[kind] = .queued
        queue.append(kind)
        pump(app: app)
    }

    /// «Разрешить всё»: «да» на каждый вопрос, кроме машин — о каждой спрашиваю отдельно.
    /// Вопрос о сейфе ждёт, пока сейф закрыт; ответ — остался ли он ждать пароля.
    @discardableResult
    func answerAll(app: AppModel) -> Bool {
        for question in asking where question.answeredTogether && !needsSafe(question.kind, app: app) {
            answer(question.kind, yes: true, app: app)
        }
        return asking.contains { $0.kind == .module(.safe) }
    }

    /// Передумал: спросить снова после «не сейчас» или убрать из очереди, пока не начато.
    func reconsider(_ kind: CleanupQuestion.Kind) {
        switch answer(for: kind) {
        case .declined:
            answers[kind] = .asking
        case .queued:
            queue.removeAll { $0 == kind }
            answers[kind] = .asking
        default:
            break
        }
    }

    /// Остановить то, что делается сейчас. Сделанное до остановки остаётся.
    func stop() { workToken.cancel() }

    private func record(_ decisions: [DecisionStore.Decision]) {
        do {
            try store?.record(decisions)
        } catch {
            storeProblem = error.localizedDescription
        }
    }

    // MARK: - Очередь

    private func pump(app: AppModel) {
        guard !working, !queue.isEmpty else { return }
        let kind = queue.removeFirst()
        guard let question = question(kind) else { return pump(app: app) }
        working = true
        let token = CancelToken()
        workToken = token
        // Выход во время работы спросит и доведёт остановку до конца, как при переносе.
        let operation = app.beginOperation { token.cancel() }
        answers[kind] = .running(Progress(index: 0, count: max(question.items.count, 1), item: "", phase: "Подготовка", fraction: 0))
        let home = app.rules.home
        Task {
            if freeBefore == nil { freeBefore = await Self.freeSpace(home: home) }
            if let outcome = await perform(question, app: app, token: token) {
                answers[kind] = .done(outcome)
            } else {
                answers[kind] = .asking
            }
            // «Остановить» или выход из программы останавливает и очередь: ждавшие своего черёда
            // снова ждут ответа, а не начинаются сами.
            if token.isCancelled {
                for waiting in queue { answers[waiting] = .asking }
                queue = []
            }
            freeNow = await Self.freeSpace(home: home)
            working = false
            app.endOperation(operation)
            app.space.invalidateAll()
            app.refreshVolumes()
            if question.action == .safe { app.history.reload(volumes: app.historyVolumes) }
            settle(app: app)
            pump(app: app)
        }
    }

    /// nil — не выполнено и спросить надо снова (причина — в `hints`).
    private func perform(_ question: CleanupQuestion, app: AppModel, token: CancelToken) async -> Outcome? {
        switch question.kind {
        case .module(let module): return await performItems(question, action: module.action, app: app, token: token)
        case .docker: return await performDocker(question, app: app)
        case .machine: return await performMachine(question)
        }
    }

    private func performItems(_ question: CleanupQuestion, action: CleanupAction, app: AppModel,
                              token: CancelToken) async -> Outcome {
        let kind = question.kind
        // «Да» — решение по каждому объекту вопроса. Запоминается сразу, даже если выполнение
        // потом остановят: выбор человек сделал. На этом учатся привычки.
        record(question.items.map {
            DecisionStore.Decision(path: $0.id, action: action, bytes: $0.bytes, suggested: action, kind: $0.kind, modified: $0.modified)
        })
        let rules = app.rules
        let throttle = Throttle()
        let items = question.items
        var outcome = Outcome()
        items: for (index, item) in items.enumerated() {
            if token.isCancelled {
                outcome.cancelled = true
                break
            }
            let name = item.url.lastPathComponent
            answers[kind] = .running(Progress(index: index + 1, count: items.count, item: name, phase: Self.phase(action), fraction: 0))
            switch action {
            case .keep:
                break
            case .backup:
                // Сравниваем пути, а не URL: «папка» и «папка/» — одно и то же.
                let path = item.url.standardizedFileURL.path
                if !app.backup.sources.contains(where: { $0.standardizedFileURL.path == path }) {
                    app.backup.sources.append(item.url)
                }
                outcome.done += 1
            case .trash where item.duplicateGroup != nil:
                if Demo.isOn {
                    outcome.done += 1
                    outcome.bytes += item.bytes
                    outcome.duplicates += 1
                    continue items
                }
                // Сверяем с копией, которая остаётся и всё ещё на месте (папку с ней могли убрать в сейф).
                guard let reference = question.keepers.first(where: {
                    $0.duplicateGroup == item.duplicateGroup && FileManager.default.fileExists(atPath: $0.url.path)
                }) else {
                    outcome.problems.append("«\(name)» осталось на месте: копии, с которой его можно сверить, на месте уже нет.")
                    continue items
                }
                answers[kind] = .running(Progress(index: index + 1, count: items.count, item: name, phase: "Сверка с копией", fraction: 0))
                let url = item.url
                let total = max(item.bytes, 1)
                let compared = Counter()
                do {
                    // Сверяется содержимое, а не отпечаток из поиска: файл могли изменить после него.
                    let trashedAt = try await Task.detached(priority: .userInitiated) { () -> (url: URL, identity: FileIdentity?)?? in
                        let same = try DuplicateFinder.sameContent(url, reference.url, isCancelled: { token.isCancelled }) { read in
                            let done = compared.add(Int64(read))
                            guard throttle.ready() else { return }
                            Task { @MainActor in
                                if case .running(var current) = self.answers[kind], current.item == name {
                                    current.fraction = min(1, Double(done) / Double(total))
                                    self.answers[kind] = .running(current)
                                }
                            }
                        }
                        guard same else { return .none }
                        return .some(try Self.trash(url))
                    }.value
                    guard let trashedAt else {
                        outcome.problems.append("«\(name)» осталось на месте: после поиска оно изменилось и больше не совпадает с «\(reference.url.lastPathComponent)».")
                        continue items
                    }
                    outcome.done += 1
                    outcome.bytes += item.bytes
                    outcome.duplicates += 1
                    if let trashedAt {
                        outcome.trashedItems.append(TrashedItem(original: url, inTrash: trashedAt.url, bytes: item.bytes, identity: trashedAt.identity))
                    }
                } catch is CancellationError {
                    outcome.cancelled = true
                    break items
                } catch {
                    outcome.problems.append("«\(name)» не удалось отправить в Корзину: \(error.localizedDescription)")
                }
            case .trash:
                if Demo.isOn {
                    outcome.done += 1
                    outcome.bytes += item.bytes
                    continue items
                }
                let url = item.url
                // Программу могли открыть уже после поиска: кеш занятой программы на ходу не удаляем.
                if let busy = CleanupPlanner.busy(home: rules.home, running: Self.runningApplications())[url.path] {
                    outcome.problems.append("«\(name)» осталось на месте. \(busy)")
                    continue items
                }
                do {
                    let trashedAt = try await Task.detached(priority: .userInitiated) { try Self.trash(url) }.value
                    outcome.done += 1
                    outcome.bytes += item.bytes
                    if let trashedAt {
                        outcome.trashedItems.append(TrashedItem(original: url, inTrash: trashedAt.url, bytes: item.bytes, identity: trashedAt.identity))
                    }
                } catch {
                    outcome.problems.append("«\(name)» не удалось отправить в Корзину: \(error.localizedDescription)")
                }
            case .safe:
                guard let volume = app.safeVolume ?? (Demo.isOn ? Demo.safeVolume : nil) else {
                    outcome.problems.append("«\(name)»: сейф закрыт — осталось на месте.")
                    continue items
                }
                if Demo.isOn {
                    outcome.done += 1
                    outcome.bytes += item.bytes
                    continue items
                }
                let source = item.url
                let shown = Set(item.cautions)
                let plan = await Task.detached(priority: .userInitiated) {
                    SafeMover(rules: rules).plan(source: source, volume: volume, isCancelled: { token.isCancelled })
                }.value
                if token.isCancelled {
                    outcome.cancelled = true
                    break items
                }
                guard plan.canProceed else {
                    let reason = (plan.verdict.isBlocked ? plan.verdict.notes : plan.check.blockers).first ?? "перенос невозможен"
                    outcome.problems.append("«\(name)»: \(reason)")
                    continue items
                }
                // Оговорки, которых человек не видел, когда разрешал (например, что папку меняли вчера), —
                // повод спросить отдельно, а не перенести молча.
                if case .caution(let notes) = plan.verdict, let unseen = notes.first(where: { !shown.contains($0) }) {
                    outcome.problems.append("«\(name)» осталось на месте: \(unseen) Перенесите вручную в «Освободить место», если уверены.")
                    continue items
                }
                do {
                    let moved = try await Task.detached(priority: .userInitiated) {
                        try SafeMover(rules: rules).execute(plan, deleteOriginal: true, acceptCautions: true,
                                                            isCancelled: { token.isCancelled }) { progress in
                            guard throttle.ready() else { return }
                            Task { @MainActor in
                                if case .running(var current) = self.answers[kind], current.item == name {
                                    current.phase = progress.phase.rawValue
                                    current.fraction = progress.fraction
                                    self.answers[kind] = .running(current)
                                }
                            }
                        }
                    }.value
                    outcome.done += 1
                    outcome.bytes += moved.bytes
                } catch is CancellationError {
                    outcome.cancelled = true
                    break items
                } catch {
                    outcome.problems.append("«\(name)»: \(error.localizedDescription)")
                }
            }
        }
        return outcome
    }

    /// Кеш сборки и образы без контейнеров. Тома не трогаются.
    private func performDocker(_ question: CleanupQuestion, app: AppModel) async -> Outcome {
        let kind = question.kind
        var outcome = Outcome()
        answers[kind] = .running(Progress(index: 1, count: 1, item: "Docker", phase: "Очистка", fraction: 0))
        if Demo.isOn {
            outcome.done = 1
            outcome.bytes = question.bytes
            return outcome
        }
        let service = DockerService()
        let rawBefore = service.rawDiskBytes()
        let targets = Set(question.docker.keys)
        do {
            let reclaimed = try await Task.detached(priority: .userInitiated) { try service.prune(targets) }.value
            answers[kind] = .running(Progress(index: 1, count: 1, item: "Docker", phase: "Жду, пока Docker вернёт место Mac", fraction: 1))
            _ = await DockerModel.settle(service, before: rawBefore)
            outcome.done = 1
            outcome.bytes = reclaimed ?? question.bytes
        } catch {
            outcome.problems.append("Docker: \(error.localizedDescription)")
        }
        // Раздел «Docker» показывал размеры до очистки.
        if app.docker.status == .ready { app.docker.reload(app: app) }
        return outcome
    }

    /// Машина — в Корзину целиком. Пока открыт UTM, не трогаем: машина может работать.
    private func performMachine(_ question: CleanupQuestion) async -> Outcome? {
        guard let machine = question.machine else { return Outcome() }
        let kind = question.kind
        answers[kind] = .running(Progress(index: 1, count: 1, item: machine.name, phase: "В Корзину", fraction: 0))
        if Demo.isOn { return Outcome(done: 1, bytes: machine.bytes) }
        if Self.runningApplications()[UTMMachines.bundleIdentifier] != nil {
            hints[kind] = "UTM открыт: пока он работает, машину удалять нельзя. Закройте UTM и ответьте ещё раз."
            return nil
        }
        record([DecisionStore.Decision(path: machine.url.path, action: .trash, bytes: machine.bytes, suggested: .trash,
                                       kind: .folder, modified: machine.modified)])
        var outcome = Outcome()
        let url = machine.url
        do {
            let trashedAt = try await Task.detached(priority: .userInitiated) { try Self.trash(url) }.value
            outcome.done = 1
            outcome.bytes = machine.bytes
            if let trashedAt {
                outcome.trashedItems.append(TrashedItem(original: url, inTrash: trashedAt.url, bytes: machine.bytes, identity: trashedAt.identity))
            }
        } catch {
            outcome.problems.append("«\(machine.name)» не удалось отправить в Корзину: \(error.localizedDescription)")
        }
        return outcome
    }

    /// Ответили на всё и всё сделано — итог разбора запоминается.
    private func settle(app: AppModel) {
        guard isSettled else { return }
        recordRun(home: app.rules.home)
    }

    /// Итог разбора — один раз и только если что-то сделано.
    private func recordRun(home: URL) {
        guard hasDone, !runRecorded else { return }
        runRecorded = true
        var trashed: Int64 = 0
        var moved: Int64 = 0
        var added = 0
        var failures = 0
        for question in questions {
            guard case .done(let outcome) = answer(for: question.kind) else { continue }
            failures += outcome.problems.count
            switch question.action {
            case .trash: trashed += outcome.bytes
            case .safe: moved += outcome.bytes
            case .backup: added += outcome.done
            case .keep: break
            }
        }
        let run = DecisionStore.Run(trashedBytes: trashed, movedBytes: moved, addedToBackup: added, failures: failures)
        try? store?.recordRun(run)
        lastRun = run
        loadHabits(home: home)
    }

    // MARK: - Не предлагать

    /// Больше не предлагать объект (папку — вместе со всем, что внутри). Из вопроса он уходит сразу.
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
        suggestions.removeAll { $0.id == path || $0.id.hasPrefix(path + "/") }
        // Лишняя копия без остающейся стала бы последней копией файла — такие группы уходят целиком.
        var groups: [String: Int] = [:]
        for suggestion in suggestions { if let group = suggestion.duplicateGroup { groups[group, default: 0] += 1 } }
        suggestions.removeAll { $0.duplicateGroup.map { (groups[$0] ?? 0) < 2 } ?? false }
        rebuild()
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

    /// Собирает заново вопросы, на которые ещё не ответили. На что ответили, то остаётся как было.
    private func rebuild() {
        let fresh = CleanupQuestions.build(suggestions, docker: docker, machines: machines, keptMachines: keptMachines)
        questions = questions.compactMap { old in
            guard answer(for: old.kind) == .asking else { return old }
            return fresh.first { $0.kind == old.kind }
        }
    }

    // MARK: - Поиск

    func scan(app: AppModel) {
        guard !isBusy else { return }
        recordRun(home: app.rules.home)
        clear()
        let rules = app.rules
        let memory = (try? store?.lastDecisions()) ?? [:]
        let habits = (try? store?.history()).map { HabitModel(history: $0, home: rules.home) }
        let ignored = Set((try? store?.ignoredPaths()) ?? [])
        keptMachines = Set(memory.filter { $0.value == .keep }.keys)
        if Demo.isOn {
            show(Demo.cleanupSuggestions(memory: memory, habits: habits), docker: Demo.dockerUsage, idle: nil,
                 machines: Demo.machines())
            return
        }
        let token = CancelToken()
        scanToken = token
        let sources = app.backup.sources.map(\.standardizedFileURL.path)
        // Кеш открытой программы в вопрос не входит: удалять его на ходу не стоит.
        let busy = CleanupPlanner.busy(home: rules.home, running: Self.runningApplications())
        let store = store
        stage = .scanning(ScanProgress())
        let throttle = Throttle(interval: 0.2)
        let tally = ScanTally()
        Task {
            // Docker и машины UTM — параллельно с поиском по папкам: docker system df думает десятки секунд.
            async let apps = Task.detached(priority: .userInitiated) { () -> (usage: DockerUsage?, idle: Int64?, machines: [UTMMachine]) in
                let service = DockerService()
                var usage: DockerUsage?
                var idle: Int64?
                if service.isInstalled {
                    if (try? service.ensureRunning()) != nil { usage = service.usage() } else { idle = service.rawDiskBytes() }
                }
                let machines = UTMMachines.list(in: UTMMachines.folder(home: rules.home), isCancelled: { token.isCancelled })
                return (usage, idle, machines)
            }.value
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
                    // Промежуточный итог — по тем же правилам, что и вопросы: видно, что поиск чего-то стоит.
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
            if case .scanning(var progress) = stage, !token.isCancelled {
                progress.current = "Docker и виртуальные машины UTM…"
                stage = .scanning(progress)
            }
            let external = await apps
            guard !token.isCancelled else {
                stage = .idle
                return
            }
            show(found, docker: external.usage, idle: external.idle, machines: external.machines)
        }
    }

    private func show(_ found: [CleanupSuggestion], docker: DockerUsage?, idle: Int64?, machines: [UTMMachine]) {
        suggestions = found
        self.docker = docker
        dockerIdle = idle
        self.machines = machines
        questions = CleanupQuestions.build(found, docker: docker, machines: machines, keptMachines: keptMachines)
        stage = .review
    }

    private func clear() {
        questions = []
        answers = [:]
        hints = [:]
        queue = []
        suggestions = []
        docker = nil
        dockerIdle = nil
        machines = []
        freeBefore = nil
        freeNow = nil
        erased = 0
        erasedBytes = 0
        trashProblems = []
        runRecorded = false
    }

    /// Открытые программы: идентификатор → название.
    private static func runningApplications() -> [String: String] {
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { running[id] = app.localizedName ?? id }
        }
        return running
    }

    /// В Корзину; ответ — где объект лежит теперь и какой это файл (nil, если macOS не сказала, куда положила).
    nonisolated private static func trash(_ url: URL) throws -> (url: URL, identity: FileIdentity?)? {
        let identity = FileIdentity.of(url)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?).map { ($0, identity) }
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

    // MARK: - Вернуть или удалить насовсем

    /// Возвращает из Корзины на прежние места то, что туда отправил ответ на этот вопрос.
    /// Для вернутого запоминается «оставить»: о нём больше не спрошу.
    func restore(_ kind: CleanupQuestion.Kind, app: AppModel) {
        guard case .done(var outcome) = answer(for: kind), finishing == nil, !outcome.trashedItems.isEmpty else { return }
        finishing = "Возвращаю из Корзины…"
        let items = outcome.trashedItems
        let home = app.rules.home
        Task {
            let (back, problems) = await Self.putBack(items)
            record(back.map { DecisionStore.Decision(path: $0.original.path, action: .keep, bytes: $0.bytes, suggested: .trash) })
            let returned = Set(back.map(\.inTrash))
            outcome.trashedItems.removeAll { returned.contains($0.inTrash) }
            outcome.restored += back.count
            outcome.problems += problems
            answers[kind] = .done(outcome)
            freeNow = await Self.freeSpace(home: home)
            finishing = nil
            loadHabits(home: home)
            app.space.invalidateAll()
        }
    }

    /// Удаляет насовсем из Корзины ровно то, что туда отправил этот разбор: место освобождается сразу.
    /// Остальное в Корзине не трогается.
    func eraseTrashed(app: AppModel) {
        let items = trashedItems
        guard finishing == nil, !items.isEmpty else { return }
        finishing = "Удаляю из Корзины…"
        let home = app.rules.home
        Task {
            let (gone, problems) = await Self.erase(items)
            let erasedPaths = Set(gone.map(\.inTrash))
            for question in questions {
                guard case .done(var outcome) = answer(for: question.kind) else { continue }
                outcome.trashedItems.removeAll { erasedPaths.contains($0.inTrash) }
                answers[question.kind] = .done(outcome)
            }
            erased += gone.count
            erasedBytes += gone.reduce(0) { $0 + $1.bytes }
            trashProblems += problems
            freeNow = await Self.freeSpace(home: home)
            finishing = nil
        }
    }

    nonisolated private static func putBack(_ items: [TrashedItem]) async -> ([TrashedItem], [String]) {
        await Task.detached(priority: .userInitiated) { () -> ([TrashedItem], [String]) in
            let fm = FileManager.default
            var back: [TrashedItem] = []
            var problems: [String] = []
            for item in items {
                let name = item.original.lastPathComponent
                guard fm.fileExists(atPath: item.inTrash.path) else {
                    problems.append("«\(name)»: в Корзине его уже нет.")
                    continue
                }
                guard item.isStillInTrash else {
                    problems.append("«\(name)»: в Корзине под этим именем теперь другой файл — его не трогаю.")
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
    }

    nonisolated private static func erase(_ items: [TrashedItem]) async -> ([TrashedItem], [String]) {
        await Task.detached(priority: .userInitiated) { () -> ([TrashedItem], [String]) in
            var gone: [TrashedItem] = []
            var problems: [String] = []
            for item in items {
                do {
                    // Удаляется насовсем, поэтому только то самое, что туда отправил разбор: файл,
                    // выброшенный потом с тем же именем, мог лечь на тот же путь.
                    if FileManager.default.fileExists(atPath: item.inTrash.path) {
                        guard item.isStillInTrash else {
                            problems.append("«\(item.original.lastPathComponent)»: в Корзине под этим именем теперь другой файл — его не трогаю.")
                            continue
                        }
                        try FileManager.default.removeItem(at: item.inTrash)
                    }
                    gone.append(item)
                } catch {
                    problems.append("«\(item.original.lastPathComponent)»: \(error.localizedDescription)")
                }
            }
            return (gone, problems)
        }.value
    }

    /// Остановить поиск.
    func cancel() { scanToken.cancel() }

    /// К началу: после ответов или чтобы бросить разбор.
    func reset(app: AppModel) {
        guard !isBusy else { return }
        recordRun(home: app.rules.home)
        clear()
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
