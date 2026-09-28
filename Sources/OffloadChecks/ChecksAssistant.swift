import Darwin
import Foundation
import OffloadCore

// AI-помощник: что уходит модели (секреты — никогда), как разбирается ответ и как правила OffLoadAI
// поправляют советы. Живой вопрос к Claude Code — только с OFFLOAD_ASSISTANT_LIVE=1: он платный и идёт в сеть.
// Вызывается из main.swift; check/section берутся оттуда же — это один модуль.

func checksAssistant() {
    let home = scratch.appendingPathComponent("assistant-home", isDirectory: true)
    let docs = home.appendingPathComponent("Documents", isDirectory: true)
    let rules = SafetyRules(home: home)

    section("Помощник: что уходит модели") {
        try write("Список покупок\nмолоко\nхлеб\n", to: docs.appendingPathComponent("список.txt"))
        try write("DATABASE_URL=postgres://admin:hunter2@db/prod\n", to: docs.appendingPathComponent(".env"))
        try write("[core]\nurl = https://bob:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/x\npassword = hunter2\n",
                  to: docs.appendingPathComponent("notes.ini"))
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n", to: docs.appendingPathComponent("id_ed25519"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 1]).write(to: docs.appendingPathComponent("photo.txt"))
        // Пароль в обычной заметке: файл не похож на секрет по имени, но его начало не уходит вовсе — даже по кусочку.
        try write("Wi-Fi на даче\npassword: dacha-2026\n", to: docs.appendingPathComponent("дача.md"))
        try write("Пароль от почты: qwerty123\n", to: docs.appendingPathComponent("почта.txt"))
        // Выгрузка паролей из Safari: таблицы не читаются вовсе.
        try write("Title,URL,Username,Password,Notes,OTPAuth\nexample.com,https://example.com/,ivan@mail.ru,Qwerty-2026!,,\n",
                  to: docs.appendingPathComponent("Passwords.csv"))
        try write("бот для дачи\n123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ\n", to: docs.appendingPathComponent("бот.txt"))
        try write("карта\nAIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY\n", to: docs.appendingPathComponent("карта.md"))
        try write("вход\neyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U\n",
                  to: docs.appendingPathComponent("вход.txt"))
        try write("кошелёк\nabandon ability able about above absent absorb abstract absurd abuse access accident\n",
                  to: docs.appendingPathComponent("кошелёк.txt"))
        try write("зарплатная\n4276 3800 1234 5678\n", to: docs.appendingPathComponent("банк.txt"))
        try write("лог лежит в \(home.path)/Library/Logs\n", to: docs.appendingPathComponent("журнал.md"))
        try write(String(repeating: "строка\n", count: 60_000), to: docs.appendingPathComponent("большой.log"))

        func preview(_ name: String) -> String? { AssistantFacts.preview(docs.appendingPathComponent(name), home: rules.home) }
        check(preview("список.txt")?.contains("молоко") == true, "начало обычного текстового файла — уходит (если разрешено)")
        check(preview(".env") == nil, ".env не читается вовсе")
        check(preview("id_ed25519") == nil, "закрытый ключ не читается вовсе")
        // notes.ini с токеном — секрет по содержимому: не читается целиком.
        check(preview("notes.ini") == nil, "файл настроек с токеном не читается")
        check(preview("photo.txt") == nil, "двоичное под видом .txt — не читается")
        check(preview("большой.log") == nil, "файл больше 256 КБ не читается")
        check(preview("дача.md") == nil, "заметка с паролем не уходит вовсе — даже по кусочку")
        check(preview("почта.txt") == nil, "пароль по-русски («Пароль от почты: …») — тоже")
        check(preview("Passwords.csv") == nil, "выгрузка паролей из Safari (.csv) не читается: таблицы не уходят")
        check(preview("бот.txt") == nil, "токен Telegram-бота узнаётся по виду")
        check(preview("карта.md") == nil, "ключ Google — тоже")
        check(preview("вход.txt") == nil, "и JWT")
        check(preview("кошелёк.txt") == nil, "фраза восстановления кошелька не уходит")
        check(preview("банк.txt") == nil, "номер карты не уходит")
        let log = preview("журнал.md")
        check(log?.contains(rules.home.path) == false && log?.contains("~/Library/Logs") == true,
              "домашняя папка в тексте файла заменена на «~»")
        for plain in ["Рецепт борща\nсвёкла, капуста, картофель", "Встреча в 15:30, кабинет 204", "let total = items.reduce(0, +)",
                      "Инструкция: https://example.com/docs/guide/getting-started", "Отпуск 2023 — фото в папке «Лето»",
                      "import Header from '/Users/Ivan/Projects/MyApp2/src/components/Header'"] {
            check(!AssistantFacts.looksSecret(plain), "обычный текст не принят за секрет: «\(plain.prefix(30))»")
        }

        let items = SpaceScanner.children(of: docs).map { SpaceScanner.measure($0, rules: rules) }
        let quiet = AssistantFacts.build(AssistantFacts.pick(items), home: rules.home)
        check(quiet.allSatisfy { $0.preview == nil }, "по умолчанию начало файлов не уходит вовсе")
        let facts = AssistantFacts.build(AssistantFacts.pick(items), home: rules.home, previews: true)
        let message = AssistantPrompt.user(facts, question: "что можно удалить?", now: Date(timeIntervalSince1970: 1_790_467_200))
        check(message.contains("молоко"), "с разрешением начало обычного файла уходит")
        check(["hunter2", "ghp_", "PRIVATE KEY", "dacha-2026", "qwerty123", "Qwerty-2026", "AAHdqTcv", "AIzaSy", "eyJhbGci", "abandon ability", "4276 3800"]
                .allSatisfy { !message.contains($0) },
              "ни пароля, ни токена, ни ключа, ни номера карты в сообщении нет")
        check(message.contains("\"~/Documents/список.txt\""), "пути — от домашней папки, без имени пользователя (и «/» без экранирования)")
        check(!message.contains(rules.home.path) && !message.contains(home.path), "полный путь с именем пользователя не уходит")
        check(message.contains("что можно удалить?"), "вопрос человека — в сообщении")
        check(message.contains("Система: macOS"), "модель знает, что это Mac")
        check(facts.map(\.id) == (1...facts.count).map(String.init), "номера объектов — по порядку, с единицы")

        let big = (0..<200).map { index in
            SpaceItem(url: docs.appendingPathComponent("f\(index)"), bytes: Int64(index), modified: nil, isDirectory: false,
                      accessDenied: false, verdict: .safe, isMeasured: true)
        }
        let picked = AssistantFacts.pick(big)
        check(picked.count == AssistantFacts.maxItems && picked.first?.bytes == 199, "уходит не больше 120 объектов, самые крупные")
    }

    section("Помощник: папки и облако") {
        let project = docs.appendingPathComponent("app", isDirectory: true)
        try write("x", to: project.appendingPathComponent("README.md"))
        try write("KEY=1", to: project.appendingPathComponent(".env"))
        try write("x", to: project.appendingPathComponent("credentials.json"))
        let fact = AssistantFacts.build([SpaceScanner.measure(project, rules: rules)], home: rules.home).first
        check(fact?.inside == ["README.md"], "имена внутри папки — без секретов")
        check(fact?.path == "~/Documents/app" && fact?.isFolder == true, "папка — путём от домашней")
        // Файл только в облаке (dataless) нельзя сделать без File Provider; проверяем, что флаг вообще читается.
        let plain = docs.appendingPathComponent("список.txt")
        var info = stat()
        check(lstat(plain.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) == 0, "обычный файл — не dataless, читается")
    }

    section("Помощник: разбор ответа и правила поверх советов") {
        let facts = [
            FileFact(id: "1", path: "~/Library", isFolder: true, bytes: 90_000_000_000, modified: nil, verdict: .blocked("Данные программ.")),
            FileFact(id: "2", path: "~/Projects/app", isFolder: true, bytes: 3_000_000_000, modified: nil, verdict: .caution(["Внутри git."])),
            FileFact(id: "3", path: "~/Downloads/Setup.dmg", isFolder: false, bytes: 100_000_000, modified: nil, verdict: .safe, canTrash: true),
            FileFact(id: "4", path: "~/Documents/паспорт.pdf", isFolder: false, bytes: 2_000_000, modified: nil, verdict: .safe),
            // Файл из «Загрузок», который помощник назвал мусором, — например, поддавшись его имени или тексту.
            FileFact(id: "5", path: "~/Downloads/Договор.pdf", isFolder: false, bytes: 1_000_000, modified: nil, verdict: .safe),
        ]
        let answer = """
            {"summary":"ok","items":[
              {"id":"1","importance":"junk","action":"trash","reason":"кеш"},
              {"id":"2","importance":"minor","action":"trash","reason":"старый проект"},
              {"id":"3","importance":"junk","action":"trash","reason":"установщик"},
              {"id":"4","importance":"important","action":"trash","reason":"?"},
              {"id":"5","importance":"junk","action":"trash","reason":"мусор"},
              {"id":"99","importance":"junk","action":"trash","reason":"выдуманный"},
              {"id":"3","importance":"important","action":"keep","reason":"повтор"}]}
            """
        let parsed = try AssistantPrompt.parse(text: answer, facts: facts, provider: "проверка", cost: nil)
        func advice(_ id: String) -> Advice? { parsed.items.first { $0.id == id } }
        check(parsed.items.count == 5, "чужой id и повтор отброшены")
        check(advice("1")?.action == .keep && advice("1")?.overruled != nil, "запрещённое правилами — только «оставить»")
        check(advice("2")?.action == .safe, "с оговорками — не в Корзину, а в сейф")
        check(advice("3")?.action == .trash && advice("3")?.overruled == nil, "то, что правила разрешают удалить, — в Корзину, как советовал")
        check(advice("4")?.action == .safe, "важное в Корзину не уходит")
        check(advice("5")?.action == .safe && advice("5")?.overruled?.contains("создаётся заново") == true,
              "личный файл, названный мусором, в Корзину не уходит — только в сейф, и сказано почему")
        let listed = AssistantPrompt.user([facts[2], facts[4]], question: nil)
        check(listed.contains(#""trash":"allowed""#) && listed.components(separatedBy: #""trash":"allowed""#).count == 2,
              "модель видит, что удалить можно только разрешённое правилами")
        expectError("ответ не по форме — ошибка, а не пустой список", {
            _ = try AssistantPrompt.parse(text: "[1,2]", facts: facts, provider: "проверка", cost: nil)
        }, matching: { ($0 as? AssistantError)?.kind == .badAnswer })
    }

    section("Помощник: удалить можно только то, что разрешают правила «Разобрать»") {
        let now = Date()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let cache = home.appendingPathComponent(".cache/tool", isDirectory: true)
        func item(_ url: URL, daysAgo: Double, folder: Bool = false, verdict: Verdict = .safe) -> SpaceItem {
            SpaceItem(url: url, bytes: 500_000_000, modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: folder,
                      accessDenied: false, verdict: verdict, isMeasured: true)
        }
        // Пути выдуманные: правила решают по сведениям, а не по диску (дата появления в папке у них неизвестна).
        let trash = AssistantTrash(planner: CleanupPlanner(now: now, home: home, regenerable: [cache.path: "Кеш — создаётся заново."]),
                                   encrypted: { $0.lastPathComponent == "Личное.dmg" })
        check(trash.allows(item(downloads.appendingPathComponent("Setup.dmg"), daysAgo: 30)), "старый установщик — можно")
        check(trash.allows(item(cache, daysAgo: 1, folder: true)), "место, которое создаётся заново, — можно")
        check(!trash.allows(item(downloads.appendingPathComponent("Setup.pkg"), daysAgo: 2)), "установщик, скачанный на днях, — нельзя: его могли ещё не поставить")
        check(!trash.allows(item(downloads.appendingPathComponent("Договор.pdf"), daysAgo: 400)), "личный файл — нельзя, хоть и старый")
        check(!trash.allows(item(downloads.appendingPathComponent("выгрузка", isDirectory: true), daysAgo: 400, folder: true)), "папка — нельзя")
        check(!trash.allows(item(downloads.appendingPathComponent("Личное.dmg"), daysAgo: 400)), "зашифрованный образ — нельзя: это не установщик")
        check(!trash.allows(item(downloads.appendingPathComponent("Old.dmg"), daysAgo: 30, verdict: .caution(["Открыт в программе."]))),
              "с оговорками — нельзя")
        check(!trash.allows(item(cache, daysAgo: 1, folder: true, verdict: .blocked("Данные программ."))), "запрещённое правилами — нельзя")
        // Установщик со старой датой изменения (curl -R ставит дату сервера), только что появившийся в папке, — тоже нельзя.
        let fresh = downloads.appendingPathComponent("Fresh.dmg")
        try write("x", to: fresh)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: fresh.path)
        if (try? fresh.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate != nil {
            check(!trash.allows(item(fresh, daysAgo: 30)), "только что скачанный установщик со старой датой — нельзя")
        }
        let facts = AssistantFacts.build([item(downloads.appendingPathComponent("Setup.dmg"), daysAgo: 30),
                                          item(downloads.appendingPathComponent("Договор.pdf"), daysAgo: 400)],
                                         home: home, canTrash: trash.allows)
        check(facts.map(\.canTrash) == [true, false], "у каждого объекта помечено, можно ли его удалить")
    }

    section("Помощник: ответ Claude Code") {
        let facts = [FileFact(id: "1", path: "~/Downloads/a.zip", isFolder: false, bytes: 1, modified: nil, verdict: .safe, canTrash: true)]
        let claude = ClaudeCodeAssistant()
        let ok = try claude.read(output: #"{"is_error":false,"result":"","total_cost_usd":0.05,"structured_output":{"summary":"s","items":[{"id":"1","importance":"minor","action":"safe","reason":"r"}]}}"#,
                                 errors: "", facts: facts)
        check(ok.items.first?.action == .safe && ok.costUSD == 0.05, "структурированный ответ и цена читаются")
        let fallback = try claude.read(output: #"{"is_error":false,"result":"{\"summary\":\"s\",\"items\":[{\"id\":\"1\",\"importance\":\"junk\",\"action\":\"trash\",\"reason\":\"r\"}]}"}"#,
                                       errors: "", facts: facts)
        check(fallback.items.first?.action == .trash, "без structured_output — ответ берётся из result")
        expectError("не вошёл в учётную запись — понятная ошибка", {
            _ = try claude.read(output: #"{"is_error":true,"result":"Not logged in · Please run /login"}"#, errors: "", facts: facts)
        }, matching: { ($0 as? AssistantError)?.kind == .notSignedIn })
        expectError("нет связи — не «не вошёл»", {
            _ = try claude.read(output: #"{"is_error":true,"result":"API Error: Unable to connect to API (ConnectionRefused)"}"#, errors: "", facts: facts)
        }, matching: { ($0 as? AssistantError)?.kind == .failed })
        expectError("мусор вместо JSON — ошибка", { _ = try claude.read(output: "oops", errors: "boom", facts: facts) },
                    matching: { ($0 as? AssistantError)?.kind == .failed })
        check(!Runner.claudeDirectories.contains(where: { $0.hasPrefix(scratch.path) }) && Runner.claudeDirectories.count == 5,
              "claude ищется только в известных каталогах")
    }

    section("Помощник: ключ API, Ollama и сервер") {
        let facts = [FileFact(id: "1", path: "~/Downloads/a.zip", isFolder: false, bytes: 1, modified: nil, verdict: .safe, canTrash: true)]
        let api = ApiKeyAssistant(key: { "sk-ant-test" })
        let reply = Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"summary\":\"s\",\"items\":[{\"id\":\"1\",\"importance\":\"junk\",\"action\":\"trash\",\"reason\":\"r\"}]}"}]}"#.utf8)
        check((try? api.read(data: reply, status: 200, facts: facts))?.items.first?.action == .trash, "ответ Messages API читается из текстовых блоков")
        expectError("401 — ключ не подошёл", { _ = try api.read(data: Data(), status: 401, facts: facts) },
                    matching: { ($0 as? AssistantError)?.kind == .notSignedIn })
        expectError("отказ Claude — понятная ошибка", {
            _ = try api.read(data: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8), status: 200, facts: facts)
        }, matching: { ($0 as? AssistantError)?.kind == .badAnswer })
        check(OllamaAssistant.choose(from: ["llama3.2:3b", "qwen2.5:7b"], preferred: nil) == "qwen2.5:7b", "Ollama: сначала предпочтительная модель")
        check(OllamaAssistant.choose(from: ["llama3.2:3b", "qwen2.5:7b"], preferred: "llama3.2:3b") == "llama3.2:3b", "Ollama: выбор человека главнее")
        check(OllamaAssistant.choose(from: ["phi4"], preferred: "нет такой") == "phi4", "Ollama: иначе любая установленная")
        check(OllamaAssistant.endpoint.host == "127.0.0.1", "Ollama — только на этом компьютере")

        func problem(_ bot: BotAssistant) -> String? {
            let result = Box<String?>()
            let done = DispatchSemaphore(value: 0)
            Task.detached { result.value = await bot.problem(); done.signal() }
            done.wait()
            return result.value
        }
        check(problem(BotAssistant(client: "t", license: { "key" }, endpoint: { nil }))?.contains("ещё не запущен") == true,
              "сервер без адреса — «ещё не запущен»")
        check(problem(BotAssistant(client: "t", license: { "key" }, endpoint: { "http://example.com" }))?.contains("ещё не запущен") == true,
              "сервер только по https")
        check(problem(BotAssistant(client: "t", license: { nil }, endpoint: { "https://example.com" }))?.contains("OffLoadAI Pro") == true,
              "без ключа Pro — объяснение, где его ввести")
        let bot = BotAssistant(client: "t", license: { "key" }, endpoint: { "https://example.com" })
        let ok = Data(#"{"answer":{"summary":"s","items":[{"id":"1","importance":"minor","action":"safe","reason":"r"}]},"remaining":9}"#.utf8)
        check((try? bot.read(data: ok, status: 200, facts: facts))?.items.count == 1, "ответ сервера читается")
        expectError("402 — фраза сервера для человека", { _ = try bot.read(data: Data(#"{"error":"Вопросы закончились"}"#.utf8), status: 402, facts: facts) },
                    matching: { ($0 as? AssistantError)?.message == "Вопросы закончились" })
    }

    /// Настоящий вопрос по тем же файлам: ответ печатается, чтобы было видно, что думает модель.
    func live(_ provider: some AssistantProvider) {
        let items = SpaceScanner.children(of: docs).map { SpaceScanner.measure($0, rules: rules) }
        let facts = AssistantFacts.build(AssistantFacts.pick(items), home: rules.home)
        let result = Box<Result<AssistantAnswer, Error>?>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let problem = await provider.problem() {
                result.value = .failure(AssistantError(.notInstalled, problem))
            } else {
                do { result.value = .success(try await provider.ask(facts, question: nil)) } catch { result.value = .failure(error) }
            }
            done.signal()
        }
        done.wait()
        switch result.value {
        case .success(let answer):
            print("  ответ: \(answer.summary) ($\(answer.costUSD ?? 0))")
            for advice in answer.items { print("    \(advice.id) \(advice.importance.rawValue)/\(advice.action.rawValue): \(advice.reason)") }
            check(!answer.items.isEmpty && answer.items.allSatisfy { advice in facts.contains { $0.id == advice.id } },
                  "\(provider.title): советы по объектам из списка")
        case .failure(let error as AssistantError) where error.kind == .notInstalled:
            print("  (пропущено: \(error.message))")
        case .failure(let error):
            check(false, "\(provider.title): \(error.localizedDescription)")
        case nil:
            check(false, "ответа нет")
        }
    }

    // Живые вопросы: OFFLOAD_ASSISTANT_LIVE=1 — к Claude Code (платно, сеть), OFFLOAD_ASSISTANT_OLLAMA=1 — к Ollama на этом Mac.
    if env["OFFLOAD_ASSISTANT_LIVE"] == "1" {
        section("Помощник: живой вопрос к Claude Code") { live(ClaudeCodeAssistant(model: "haiku")) }
    }
    if env["OFFLOAD_ASSISTANT_OLLAMA"] == "1" {
        section("Помощник: живой вопрос к Ollama") { live(OllamaAssistant(preferredModel: { nil })) }
    }
}

/// Значение из асинхронной задачи для синхронных проверок.
final class Box<Value>: @unchecked Sendable {
    var value: Value

    init() where Value: ExpressibleByNilLiteral { value = nil }
}
