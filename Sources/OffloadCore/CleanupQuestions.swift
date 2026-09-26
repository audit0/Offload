import Foundation

/// Вопрос после разбора: одно «да» или «нет» на целую группу найденного. Человек не выбирает
/// по файлам и не ходит по папкам — Offload сам собирает, что можно убрать, и спрашивает разрешения.
public struct CleanupQuestion: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Найденное разбором: мусор, лишние копии, установщики, крупное и старое, проекты.
        case module(CleanupModule)
        /// Кеш сборки и образы Docker, которые не нужны ни одному контейнеру.
        case docker
        /// Виртуальная машина UTM, которую давно не запускали, — о каждой отдельно. Путь к пакету.
        case machine(String)
    }

    public var kind: Kind
    public var id: Kind { kind }
    /// С чем что-то произойдёт при «да». У Docker и машины пусто.
    public var items: [CleanupSuggestion]
    /// Копии, которые остаются: с ними лишние сверяются перед удалением.
    public var keepers: [CleanupSuggestion]
    /// Сколько освободится на Mac. Бэкап места на Mac не освобождает — у проектов ноль.
    public var bytes: Int64
    /// Что уберёт Docker и сколько каждого.
    public var docker: [DockerPruneTarget: Int64]
    public var machine: UTMMachine?
    /// Найдено, но в вопрос не вошло, — и почему (кеш открытой программы).
    public var notes: [String]

    public init(kind: Kind, items: [CleanupSuggestion] = [], keepers: [CleanupSuggestion] = [], bytes: Int64,
                docker: [DockerPruneTarget: Int64] = [:], machine: UTMMachine? = nil, notes: [String] = []) {
        self.kind = kind
        self.items = items
        self.keepers = keepers
        self.bytes = bytes
        self.docker = docker
        self.machine = machine
        self.notes = notes
    }

    /// Что будет сделано при «да».
    public var action: CleanupAction {
        switch kind {
        case .module(let module): return module.action
        case .docker, .machine: return .trash
        }
    }

    /// Отвечается вместе со всеми по «Разрешить всё». Машина — целый компьютер с системой и файлами:
    /// о каждой спрашиваем отдельно.
    public var answeredTogether: Bool {
        if case .machine = kind { return false }
        return true
    }

    /// Короткие названия того, что в вопросе, для одной строки: «Кеш npm», «Отпуск 2023.mov».
    public var labels: [String] {
        switch kind {
        case .module(.junk):
            return items.map { item in
                let known = CleanupPlanner.regenerableLocations.first { item.url.path.hasSuffix("/" + $0.path) }
                return known?.reason.components(separatedBy: " — ").first ?? item.url.lastPathComponent
            }
        case .module:
            return items.map(\.url.lastPathComponent)
        case .docker, .machine:
            return []
        }
    }
}

public enum CleanupQuestions {
    /// Машину, которую не запускали столько дней, предлагаем удалить.
    public static let machineStaleDays: Double = 30
    /// О машинах меньше этого не спрашиваем: места почти не освободится.
    public static let machineMinimumBytes: Int64 = 1_000_000_000
    /// О Docker спрашиваем, если он отдаст хотя бы столько.
    public static let dockerMinimumBytes: Int64 = 100_000_000
    /// Что убирает Docker по «да». Остановленных контейнеров здесь нет: в них бывают данные без тома.
    public static let dockerTargets: [DockerPruneTarget] = [.buildCache, .images]

    /// Вопросы в том порядке, в котором их задавать: сначала то, что пересоздаётся само,
    /// потом личное, машины — последними и каждая отдельно.
    ///
    /// `keptMachines` — машины, которые вы уже решили оставить: о них больше не спрашиваем.
    public static func build(_ suggestions: [CleanupSuggestion], docker: DockerUsage? = nil, machines: [UTMMachine] = [],
                             keptMachines: Set<String> = [], now: Date = Date()) -> [CleanupQuestion] {
        func found(_ module: CleanupModule) -> [CleanupSuggestion] { suggestions.filter { $0.module == module } }
        func total(_ items: [CleanupSuggestion]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }
        var questions: [CleanupQuestion] = []

        // Мусор. Кеш открытой программы в вопрос не входит — о нём заметка, чтобы было понятно почему.
        let junk = found(.junk)
        let removable = junk.filter { $0.action == .trash }
        if !removable.isEmpty {
            questions.append(CleanupQuestion(kind: .module(.junk), items: removable, bytes: total(removable),
                                             notes: junk.filter { $0.action == .keep && !$0.learned && !$0.habit }.map(\.reason)))
        }

        if let docker {
            var parts: [DockerPruneTarget: Int64] = [:]
            for target in dockerTargets {
                if let bytes = docker.part(target)?.reclaimable, bytes > 0 { parts[target] = bytes }
            }
            let bytes = parts.values.reduce(0, +)
            if bytes >= dockerMinimumBytes { questions.append(CleanupQuestion(kind: .docker, bytes: bytes, docker: parts)) }
        }

        // Лишние копии. Копия внутри папки, которую можно убрать в сейф, едет вместе с папкой:
        // удалить её отдельно значило бы поменять папку перед самым переносом.
        let safe = found(.safe).filter { $0.action == .safe }
        let copies = suggestions.filter { $0.duplicateGroup != nil }
        let redundant = copies.filter { $0.action == .trash && CleanupPlanner.container(of: $0, in: safe) == nil }
        if !redundant.isEmpty {
            let groups = Set(redundant.compactMap(\.duplicateGroup))
            questions.append(CleanupQuestion(kind: .module(.duplicates), items: redundant,
                                             keepers: copies.filter { $0.action != .trash && groups.contains($0.duplicateGroup ?? "") },
                                             bytes: total(redundant)))
        }

        // Установщики — все старые, кроме тех, что вы уже возвращали из Корзины.
        let installers = found(.installers).filter { $0.allowed.contains(.trash) && !($0.action == .keep && ($0.learned || $0.habit)) }
        if !installers.isEmpty {
            questions.append(CleanupQuestion(kind: .module(.installers), items: installers, bytes: total(installers)))
        }

        if !safe.isEmpty { questions.append(CleanupQuestion(kind: .module(.safe), items: safe, bytes: total(safe))) }

        let projects = found(.projects).filter { $0.action == .backup }
        if !projects.isEmpty { questions.append(CleanupQuestion(kind: .module(.projects), items: projects, bytes: 0)) }

        for machine in machines.sorted(by: { ($0.bytes, $1.url.path) > ($1.bytes, $0.url.path) })
        where machine.bytes >= machineMinimumBytes && !keptMachines.contains(machine.url.path) {
            guard let modified = machine.modified, now.timeIntervalSince(modified) >= machineStaleDays * 86_400 else { continue }
            questions.append(CleanupQuestion(kind: .machine(machine.url.path), bytes: machine.bytes, machine: machine))
        }
        return questions
    }
}
