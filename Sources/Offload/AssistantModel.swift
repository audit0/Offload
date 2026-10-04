import AppKit
import Foundation
import Observation
import OffloadCore

/// AI-помощник по файлам: смотрит на содержимое папки и говорит, что важно, что менее важно, а что мусор.
/// Сам ничего не делает — каждый совет выполняет человек, теми же путями, что и без помощника.
@MainActor
@Observable
final class AssistantModel {
    enum Stage { case idle, scanning, thinking, done, failed }

    /// Где думает помощник — по порядку: Claude Code на Mac, ключ API, локальная модель, сервер OffLoadAI.
    enum Kind: String, CaseIterable, Identifiable {
        case claudeCode, apiKey, local, server

        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .apiKey: return tr("Ключ API")
            case .local: return tr("На этом Mac")
            case .server: return tr("Сервер OffLoadAI")
            }
        }

        var detail: String {
            switch self {
            case .claudeCode: return tr("Claude Code, установленный на этом Mac, под вашей учётной записью Claude. Ключ не нужен.")
            case .apiKey: return tr("Ваш ключ Anthropic API: платите по счёту API за каждый вопрос. Ключ хранится в связке ключей macOS.")
            case .local: return tr("Модель в Ollama на этом Mac: сведения о файлах не покидают его. Медленнее и проще, чем Claude.")
            case .server: return tr("Сервер OffLoadAI передаёт вопрос Claude и ничего не хранит. Входит в OffLoadAI Pro — ни Claude Code, ни ключа не нужно.")
            }
        }

        /// Куда уходят сведения о файлах — для согласия: у каждого варианта своё.
        var destination: String {
            switch self {
            case .claudeCode: return tr("в Anthropic (Claude) — через Claude Code на этом Mac, под вашей учётной записью Claude.")
            case .apiKey: return tr("в Anthropic (Claude) — по вашему ключу API.")
            case .local: return tr("никуда: их читает модель в Ollama на этом Mac, в интернет они не уходят.")
            case .server: return tr("на сервер OffLoadAI, а он передаёт их Claude (Anthropic). Вместе с ними уходит ваш ключ OffLoadAI Pro — в нём номер ключа и имя, которое вы назвали при покупке.")
            }
        }
    }

    /// Согласие — отдельно для каждого варианта: сведения уходят в разные места. Ключи новые: прежнее общее
    /// согласие давалось на описание, по которому начало текстовых файлов уходило всегда.
    private static func consentKey(_ kind: Kind) -> String { "assistant.consent.\(kind.rawValue)" }
    private static let kindKey = "assistant.provider"
    private static let localModelKey = "assistant.ollamaModel"
    private static let serverKey = "assistant.server"
    private static let previewsKey = "assistant.previews"

    private(set) var stage: Stage = .idle
    var isBusy: Bool { stage == .scanning || stage == .thinking }
    private(set) var status: String?
    private(set) var error: String?
    private(set) var answer: AssistantAnswer?
    /// Папка, которую разбирали последней.
    private(set) var folder: URL?

    /// Готов ли выбранный вариант: nil — готов; иначе что сделать, одной фразой.
    private(set) var problem: String?
    private(set) var isChecking = false
    /// Модели, установленные в Ollama, — для выбора.
    private(set) var localModels: [String] = []
    private(set) var hasApiKey = AssistantKeychain.exists

    var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .claudeCode {
        didSet {
            guard kind != oldValue else { return }
            if !Demo.isOn { UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey) }
            error = nil
        }
    }

    /// На какие варианты человек согласился: сведения о файлах уходят туда, куда их отправляет вариант
    /// (`Kind.destination`). Без согласия на выбранный вариант помощник не запускается.
    private(set) var consented: Set<Kind> = Demo.isOn ? Set(Kind.allCases)
        : Set(Kind.allCases.filter { UserDefaults.standard.bool(forKey: AssistantModel.consentKey($0)) })
    var consent: Bool { consented.contains(kind) }

    /// Дать или отозвать согласие на выбранный вариант. Отозванное действует сразу: начатый вопрос прерывается.
    func setConsent(_ given: Bool) {
        if given { consented.insert(kind) } else { consented.remove(kind) }
        if !Demo.isOn { UserDefaults.standard.set(given, forKey: Self.consentKey(kind)) }
        if !given { cancel() }
    }

    /// Показывать ли помощнику начало небольших текстовых файлов. По умолчанию — нет: имя, размер и дата
    /// обычно и так говорят, что это за файл, а в тексте бывает то, что уходить не должно.
    var sendsPreviews: Bool = UserDefaults.standard.bool(forKey: previewsKey) {
        didSet { if !Demo.isOn { UserDefaults.standard.set(sendsPreviews, forKey: Self.previewsKey) } }
    }

    var localModel: String? = UserDefaults.standard.string(forKey: localModelKey) {
        didSet { if !Demo.isOn { UserDefaults.standard.set(localModel, forKey: Self.localModelKey) } }
    }

    /// Объект по номеру из ответа — настоящий путь, а не тот, что видел помощник.
    @ObservationIgnored private var items: [String: SpaceItem] = [:]
    func item(_ id: String) -> SpaceItem? { items[id] }

    /// Что уже сделано по совету: «в Корзине», «в сейфе».
    private(set) var done: [String: String] = [:]
    func markDone(_ id: String, _ outcome: String) { done[id] = outcome }

    /// Что по советам ушло в Корзину и где лежит теперь — чтобы вернуть здесь же, как в «Разобрать».
    private(set) var trashed: [String: CleanupModel.TrashedItem] = [:]
    func canPutBack(_ id: String) -> Bool { trashed[id] != nil }

    @ObservationIgnored private var task: Task<Void, Never>?

    func saveApiKey(_ key: String?) {
        guard !Demo.isOn else { return }
        if !AssistantKeychain.save(key) {
            error = tr("Не удалось сохранить ключ в связке ключей macOS.")
        } else {
            error = nil
        }
        hasApiKey = AssistantKeychain.exists
    }

    /// Вариант, который спросят: с тем ключом, моделью и адресом, что выбраны сейчас.
    func provider(app: AppModel) -> any AssistantProvider {
        switch kind {
        case .claudeCode:
            return ClaudeCodeAssistant()
        case .apiKey:
            return ApiKeyAssistant(key: { AssistantKeychain.read() }, hasKey: { AssistantKeychain.exists })
        case .local:
            let chosen = localModel
            return OllamaAssistant(preferredModel: { chosen })
        case .server:
            let license = app.pro.licenseText
            let endpoint = UserDefaults.standard.string(forKey: Self.serverKey)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return BotAssistant(client: "offloadai-mac/\(version)", license: { license }, endpoint: { endpoint })
        }
    }

    /// Проверить, готов ли выбранный вариант: есть ли Claude Code, ключ, Ollama с моделью, адрес сервера.
    func check(app: AppModel) async {
        guard !Demo.isOn else {
            problem = nil
            return
        }
        let checking = kind
        isChecking = true
        let found = await provider(app: app).problem()
        let models = checking == .local ? await OllamaAssistant.installed() ?? [] : localModels
        // Пока проверяли, человек мог выбрать другой вариант — тогда ответ уже не про него.
        guard checking == kind else { return }
        problem = found
        localModels = models
        isChecking = false
    }

    func run(_ target: URL, question: String, app: AppModel) {
        guard !isBusy, consent else { return }
        folder = target
        error = nil
        answer = nil
        done = [:]
        trashed = [:]
        stage = .scanning
        status = tr("Считаю, что лежит в папке…")
        let rules = app.rules
        let asked = provider(app: app)
        let previews = sendsPreviews
        let demo = Demo.isOn
        task = Task {
            do {
                let measured: [SpaceItem]
                if Demo.isOn {
                    measured = Self.demoDownloads(home: rules.home)
                } else {
                    let children = await Task.detached(priority: .userInitiated) { SpaceScanner.children(of: target) }.value
                    let found = Collector<SpaceItem>()
                    let total = children.count
                    await SpaceScanner.scan(children, rules: rules, isCancelled: { Task.isCancelled }) { item in
                        found.append(item)
                        let count = found.all.count
                        Task { @MainActor in
                            guard self.stage == .scanning else { return }
                            self.status = tr("Считаю, что лежит в папке… \(count) из \(total)")
                        }
                    }
                    measured = found.all
                }
                try Task.checkCancellation()
                guard !measured.isEmpty else {
                    fail(tr("Папка пуста — разбирать нечего."))
                    return
                }
                let picked = AssistantFacts.pick(measured)
                items = Dictionary(uniqueKeysWithValues: picked.enumerated().map { (String($0.offset + 1), $0.element) })
                let home = rules.home
                let facts = await Task.detached(priority: .userInitiated) { () -> [FileFact] in
                    // Что можно удалить, решают правила «Разобрать», а не помощник. В демонстрации hdiutil не спрашиваем.
                    let trash = demo ? AssistantTrash(planner: CleanupPlanner(home: home), encrypted: { _ in false })
                        : AssistantTrash.current(home: home)
                    return AssistantFacts.build(picked, home: home, previews: previews, canTrash: trash.allows)
                }.value
                try Task.checkCancellation()
                stage = .thinking
                status = tr("Помощник смотрит \(facts.count) \(pluralRu(facts.count, tr("объект"), tr("объекта"), tr("объектов")))…")
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = Demo.isOn ? Self.demoAnswer(facts) : try await asked.ask(facts, question: trimmed.isEmpty ? nil : trimmed)
                stage = .done
                status = nil
            } catch is CancellationError {
                stage = .idle
                status = nil
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        status = nil
        stage = .failed
    }

    func cancel() { task?.cancel() }

    /// В Корзину — вернуть можно здесь же или из Корзины, пока её не очистили. Правила OffLoadAI проверяются ещё раз:
    /// помощник мог ошибиться, а объект — измениться с тех пор. Ответ — что помешало (nil — получилось).
    func trash(_ id: String, app: AppModel) async -> String? {
        guard let item = item(id) else { return tr("Объект не найден.") }
        if Demo.isOn {
            markDone(id, tr("в Корзине"))
            return nil
        }
        let verdict = app.rules.pathVerdict(for: item.url)
        guard verdict == .safe else {
            return tr("Правила OffLoadAI не дают отправить это в Корзину: ") + verdict.notes.joined(separator: " ")
        }
        let url = item.url
        let home = app.rules.home
        // Удалить можно только то, что разрешают правила «Разобрать», — что бы ни советовал помощник.
        // Сведения — свежие: файл могли заменить новым с тем же именем.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? item.modified
        let current = SpaceItem(url: url, bytes: item.bytes, modified: modified, isDirectory: item.isDirectory,
                                accessDenied: item.accessDenied, verdict: verdict, isMeasured: item.isMeasured)
        guard await Task.detached(priority: .userInitiated, operation: { AssistantTrash.current(home: home).allows(current) }).value else {
            return tr("Удалять OffLoadAI разрешает только то, что создаётся заново, и старые установщики. Это можно убрать в сейф.")
        }
        // Как и в «Разобрать»: то, что сейчас открыто в программе, на ходу не удаляем.
        if let holders = await Task.detached(priority: .userInitiated, operation: { SafeMover.openFiles(in: url) }).value,
           !holders.isEmpty {
            return tr("«\(url.lastPathComponent)» сейчас использует \(holders.prefix(3).joined(separator: ", ")). Закройте программу и повторите.")
        }
        do {
            let trashedAt = try await Task.detached(priority: .userInitiated) { try CleanupModel.trash(url) }.value
            if let trashedAt {
                trashed[id] = CleanupModel.TrashedItem(original: url, inTrash: trashedAt.url, bytes: item.bytes, identity: trashedAt.identity)
            }
            markDone(id, tr("в Корзине"))
            app.space.invalidateAll()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Вернуть из Корзины на прежнее место то, что туда отправил совет. Ответ — что помешало (nil — получилось).
    func putBack(_ id: String, app: AppModel) async -> String? {
        guard let item = trashed[id] else { return tr("В Корзине его уже нет.") }
        let (back, problems) = await CleanupModel.putBack([item])
        guard !back.isEmpty else { return problems.first ?? tr("Вернуть не получилось.") }
        trashed[id] = nil
        done[id] = nil
        app.space.invalidateAll()
        return nil
    }

    // MARK: - Демонстрация

    /// Вымышленные «Загрузки» для снимков и демонстрации: что там обычно лежит.
    static func demoDownloads(home: URL) -> [SpaceItem] {
        let folder = home.appendingPathComponent("Downloads", isDirectory: true)
        func item(_ name: String, _ gigabytes: Double, daysAgo: Double, isFolder: Bool = false) -> SpaceItem {
            SpaceItem(url: folder.appendingPathComponent(name, isDirectory: isFolder), bytes: Int64(gigabytes * 1_000_000_000),
                      modified: Date().addingTimeInterval(-daysAgo * 86_400), isDirectory: isFolder, accessDenied: false,
                      verdict: .safe, isMeasured: true)
        }
        return [
            item(tr("Отпуск 2023 (1).mp4"), 4.1, daysAgo: 380), item(tr("Фото с дачи.zip"), 2.3, daysAgo: 410), item("Xcode_16.4.xip", 5.8, daysAgo: 290),
            item("temp-export", 0.8, daysAgo: 200, isFolder: true), item("node-v22.11.0.pkg", 0.03, daysAgo: 320),
            item("googlechrome.dmg", 0.23, daysAgo: 500), item(tr("Договор аренды 2026.pdf"), 0.002, daysAgo: 40),
            item(tr("Выписка ЕГРН.pdf"), 0.001, daysAgo: 95),
        ]
    }

    /// Ответ для снимков и демонстрации: без сети, по вымышленным «Загрузкам».
    static func demoAnswer(_ facts: [FileFact]) -> AssistantAnswer {
        let advice = facts.map { fact -> Advice in
            switch (fact.path as NSString).lastPathComponent {
            case tr("Отпуск 2023 (1).mp4"):
                return Advice(id: fact.id, importance: .minor, action: .safe, reason: tr("Видео из отпуска с «(1)» в имени — похоже на повторную загрузку; сохранить стоит, но не на диске Mac."))
            case tr("Фото с дачи.zip"):
                return Advice(id: fact.id, importance: .minor, action: .safe, reason: tr("Архив с личными фото: нужен, но редко — место ему в сейфе."))
            case "Xcode_16.4.xip":
                return Advice(id: fact.id, importance: .junk, action: .trash, reason: tr("Архив установки Xcode: скачивается заново с сайта Apple."))
            case "temp-export":
                return Advice(id: fact.id, importance: .minor, action: .safe, reason: tr("Временная выгрузка, которую давно не открывали: в сейфе она не мешает, а понадобится — вернёте."))
            case "node-v22.11.0.pkg", "googlechrome.dmg":
                return Advice(id: fact.id, importance: .junk, action: .trash, reason: tr("Установщик уже поставленной программы."))
            default:
                return Advice(id: fact.id, importance: .important, action: .keep, reason: tr("Личный документ — оставить на месте."))
            }
        }
        return AssistantAnswer(summary: tr("В «Загрузках» около 6 ГБ мусора — архив Xcode и установщики. Видео, архив с фото и старую выгрузку лучше убрать в сейф, документы оставить."),
                               items: advice, provider: tr("Демонстрация"))
    }
}
