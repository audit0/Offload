import Foundation
import OffloadCore
import SQLite3

/// Привычки: что считается похожим, когда модель берётся решать и когда молчит.
func checksHabits() {
    let home = URL(fileURLWithPath: "/Users/q", isDirectory: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func features(_ relative: String, kind: DecisionFeatures.Kind = .folder, gb: Double = 20, daysAgo: Double? = 400) -> DecisionFeatures {
        DecisionFeatures.of(path: home.appendingPathComponent(relative).path, home: home, kind: kind, bytes: Int64(gb * 1_000_000_000),
                            modified: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, at: now)
    }
    func example(_ relative: String, _ action: CleanupAction, kind: DecisionFeatures.Kind = .folder, gb: Double = 20,
                 daysAgo: Double = 400) -> HabitModel.Example {
        HabitModel.Example(features: features(relative, kind: kind, gb: gb, daysAgo: daysAgo), action: action)
    }
    func observation(_ relative: String, gb: Double = 80, daysAgo: Double = 500, directory: Bool = true,
                     verdict: Verdict = .safe) -> CleanupObservation {
        CleanupObservation(url: home.appendingPathComponent(relative), bytes: Int64(gb * 1_000_000_000),
                           modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: directory, verdict: verdict)
    }

    section("Привычки: признаки") {
        check(features("Downloads/film.MKV", kind: .file, gb: 4) == DecisionFeatures(kind: .file, category: .video, place: "Downloads",
                                                                                  size: .large, age: .ancient),
              "видео в Загрузках: вид, место, размер и давность")
        check(features("Projects/app", kind: .project, gb: 0.05, daysAgo: 3)
              == DecisionFeatures(kind: .project, category: nil, place: "Projects", size: .small, age: .fresh),
              "у папок и проектов вида по расширению нет, место — своя папка в домашней")
        check(DecisionFeatures.category(of: "scan.PDF") == .document && DecisionFeatures.category(of: "Xcode.xip") == .installer
              && DecisionFeatures.category(of: "IMG_1.HEIC") == .image && DecisionFeatures.category(of: "notes") == .other,
              "вид файла — по расширению, без учёта регистра")
        let undated = features("Movies/x", daysAgo: nil)
        check(undated.age == .unknown && undated.size == .huge, "без даты давность неизвестна")
        let old = DecisionStore.Decision(path: home.appendingPathComponent("Movies/Съёмки").path, action: .safe,
                                         bytes: 20_000_000_000, decidedAt: now)
        check(old.features(home: home).kind == .folder && old.features(home: home).age == .unknown,
              "у решений, записанных до привычек, папка угадывается по имени без расширения")
    }

    section("Привычки: когда модель решает") {
        let target = features("Movies/Новая")
        let few = HabitModel(examples: [example("Movies/a", .keep), example("Movies/b", .keep)])
        check(few.predict(target, allowed: [.safe, .keep]) == nil, "двух похожих решений мало — решают правила")

        let three = HabitModel(examples: [example("Movies/a", .keep), example("Movies/b", .keep), example("Movies/c", .keep)])
        let prediction = three.predict(target, allowed: [.safe, .backup, .keep])
        check(prediction?.action == .keep && prediction?.agreeing == 3 && prediction?.total == 3,
              "три похожие папки из трёх оставили — модель предлагает оставить")
        check(prediction?.reason == "Похожее вы обычно оставляете (3 из 3): папки в «Фильмах» больше 10 ГБ, не менялись больше года.",
              "в причине сказано, что сочтено похожим")
        check(three.predict(target, allowed: [.safe]) == nil, "действие, которое для объекта не разрешено, не предлагается")
        check(three.predict(features("Downloads/x"), allowed: [.safe, .keep]) == nil, "папки в «Фильмах» ничего не говорят о «Загрузках»")

        let mixed = HabitModel(examples: [example("Movies/a", .keep), example("Movies/b", .keep),
                                          example("Movies/c", .safe), example("Movies/d", .safe)])
        check(mixed.predict(target, allowed: [.safe, .keep]) == nil, "решения расходятся — модель не гадает")

        let broader = HabitModel(examples: [example("Movies/a", .safe, daysAgo: 100), example("Movies/b", .safe, daysAgo: 200),
                                            example("Movies/c", .safe, daysAgo: 400)])
        check(broader.predict(target, allowed: [.safe, .keep])?.reason
              == "Похожее вы обычно убираете в сейф (3 из 3): папки в «Фильмах» больше 10 ГБ.",
              "точно похожих мало — берутся похожие без учёта давности")
        // Среди всех папок в «Фильмах» уверенно «в сейф» (9 из 11), но самые похожие расходятся.
        let strict = HabitModel(examples: [example("Movies/a", .keep), example("Movies/b", .safe), example("Movies/c", .keep)]
                                + (2...9).map { example("Movies/\($0)", .safe, gb: Double($0)) })
        check(strict.predict(target, allowed: [.safe, .keep]) == nil,
              "самые похожие решения расходятся — менее похожие их не перевешивают")

        let list = HabitModel(examples: [example("Movies/a", .safe), example("Movies/b", .safe), example("Movies/c", .safe, gb: 2),
                                         example("Movies/d", .safe, gb: 30),
                                         example("Downloads/a.dmg", .keep, kind: .file, gb: 0.5),
                                         example("Downloads/b.dmg", .keep, kind: .file, gb: 0.3),
                                         example("Downloads/c.dmg", .keep, kind: .file, gb: 0.2)]).habits()
        check(list.map(\.scope) == ["папки в «Фильмах»", "образы дисков и установщики в «Загрузках»"]
              && list.map(\.action) == [.safe, .keep] && list.first?.agreeing == 4,
              "список привычек — по местам и видам, самые подкреплённые сначала")
        check(HabitModel(examples: []).isEmpty && !three.isEmpty, "пустая модель знает, что пуста")

        let deleting = HabitModel(examples: (1...4).map { example("Downloads/\($0).dmg", .trash, kind: .file, gb: 0.5) })
        check(deleting.predict(features("Downloads/new.dmg", kind: .file, gb: 0.5), allowed: [.trash, .safe, .keep]) == nil
              && deleting.habits().isEmpty,
              "удалить привычка не предлагает никогда, даже если похожее всегда удаляли")
    }

    section("Привычки: в предложениях") {
        let keeping = HabitModel(examples: [example("Movies/a", .keep), example("Movies/b", .keep), example("Movies/c", .keep)])
        let planner = CleanupPlanner(now: now, home: home, habits: keeping)
        let item = observation("Movies/Съёмки 2019")
        let suggestion = planner.suggest(item)
        check(suggestion.action == .keep && suggestion.habit && !suggestion.learned,
              "правило советует сейф, но похожее вы оставляете — предлагается оставить, с пометкой")
        check(suggestion.module == .safe && !suggestion.preselected,
              "оставленное по привычке видно в плитке сейфа неотмеченным — с объяснением, почему")
        check(suggestion.kind == .folder && planner.suggest(CleanupObservation(url: home.appendingPathComponent("Projects/app"),
                                                                                bytes: 1, modified: nil, isDirectory: true,
                                                                                verdict: .safe, isProject: true)).kind == .project,
              "вид объекта идёт в предложение, чтобы записаться с решением")

        var remembering = planner
        remembering.memory = [item.url.path: .safe]
        check(remembering.suggest(item).action == .safe && remembering.suggest(item).learned,
              "решение по этой самой папке важнее привычки")

        let agreeing = CleanupPlanner(now: now, home: home, habits: HabitModel(examples: [example("Movies/a", .safe),
                                                                                          example("Movies/b", .safe),
                                                                                          example("Movies/c", .safe)]))
        let same = agreeing.suggest(item)
        check(same.action == .safe && same.habit && same.preselected && same.reason.hasPrefix("Похожее вы обычно убираете в сейф"),
              "правило сейф только предлагает, а вы похожее обычно туда и убираете — отмечено сразу, по привычке")
        let projects = CleanupPlanner(now: now, home: home, habits: HabitModel(examples: (1...3).map {
            example("Projects/\($0)", .backup, kind: .project)
        }))
        let project = projects.suggest(CleanupObservation(url: home.appendingPathComponent("Projects/app"), bytes: 2_000_000_000,
                                                          modified: now.addingTimeInterval(-200 * 86_400), isDirectory: true,
                                                          verdict: .safe, isProject: true))
        check(project.action == .backup && !project.habit && project.preselected,
              "привычка совпала с правилом, которое и так отмечает сразу, — объясняет правило")

        let blocked = planner.suggest(observation("Movies/Проект.fcpbundle", verdict: .blocked("пакет")))
        check(blocked.action == .keep && !blocked.habit && blocked.allowed == [.keep], "запрещённое остаётся запрещённым")

        let trashing = CleanupPlanner(now: now, home: home, habits: HabitModel(examples: [
            example("Downloads/a.mkv", .trash, kind: .file, gb: 4), example("Downloads/b.mkv", .trash, kind: .file, gb: 4),
            example("Downloads/c.mkv", .trash, kind: .file, gb: 4)]))
        let video = trashing.suggest(observation("Downloads/film.mkv", gb: 4, daysAgo: 400, directory: false))
        check(video.action != .trash && !video.allowed.contains(.trash),
              "даже если похожее вы удаляли, личный файл в Корзину не предлагается: удалять разрешают только правила")

        let installers = CleanupPlanner(now: now, home: home, habits: HabitModel(examples: (1...3).map {
            example("Downloads/\($0).dmg", .trash, kind: .file, gb: 0.5, daysAgo: 60)
        }))
        let installer = installers.suggest(observation("Downloads/Figma.dmg", gb: 0.5, daysAgo: 60, directory: false))
        check(installer.action == .keep && !installer.habit && installer.allowed.contains(.trash),
              "установщик удаляете вы сами: сколько бы похожих ни удаляли, привычка его в Корзину не предлагает")

        let copy = CleanupSuggestion(url: home.appendingPathComponent("Downloads/a.pdf"), bytes: 1, modified: nil, isDirectory: false,
                                     action: .trash, reason: "", allowed: [.trash, .keep], learned: false, cautions: [], duplicateGroup: "h")
        check(copy.kind == .copy, "копия одинакового файла записывается как копия")
    }

    section("Привычки: одинаковые файлы") {
        func copy(_ relative: String) -> DuplicateCopy {
            DuplicateCopy(url: home.appendingPathComponent(relative), allocated: 5_000_000,
                          modified: now.addingTimeInterval(-400 * 86_400), created: now.addingTimeInterval(-400 * 86_400))
        }
        func planner(_ action: CleanupAction, in place: String) -> CleanupPlanner {
            CleanupPlanner(now: now, home: home, habits: HabitModel(examples: (1...3).map {
                example("\(place)/\($0).pdf", action, kind: .copy, gb: 0.005)
            }))
        }
        let keeping = planner(.keep, in: "Downloads").suggestions([], duplicates: [
            DuplicateGroup(id: "g", bytes: 5_000_000, copies: [copy("Documents/a.pdf"), copy("Downloads/a.pdf")])])
        check(keeping.map(\.action) == [.keep, .keep] && keeping.map(\.habit) == [false, true],
              "лишнюю копию там, где копии вы оставляете, привычка предлагает оставить")
        check(keeping.last?.reason
              == "Похожее вы обычно оставляете (3 из 3): копии документов в «Загрузках» меньше 100 МБ, не менялись больше года.",
              "у копий в причине назван вид файла")
        let trashing = planner(.trash, in: "Documents").suggestions([], duplicates: [
            DuplicateGroup(id: "g", bytes: 5_000_000, copies: [copy("Documents/a.pdf"), copy("Documents/Старое/a.pdf")])])
        check(trashing.map(\.action) == [.keep, .trash] && !trashing.contains(where: \.habit),
              "привычка удалять копии не трогает ту, что остаётся, и удалений не добавляет")
        var remembering = planner(.keep, in: "Downloads")
        remembering.memory = [home.appendingPathComponent("Downloads/a.pdf").path: .trash]
        let remembered = remembering.suggestions([], duplicates: [
            DuplicateGroup(id: "g", bytes: 5_000_000, copies: [copy("Documents/a.pdf"), copy("Downloads/a.pdf")])])
        check(remembered.last?.action == .trash && remembered.last?.learned == true && remembered.last?.habit == false,
              "решение по этой самой копии важнее привычки")
    }

    section("Привычки: что считается выбором") {
        func decision(_ action: CleanupAction, suggested: CleanupAction?, path: String = "/Users/q/Movies/a") -> DecisionStore.Decision {
            DecisionStore.Decision(path: path, action: action, bytes: 20_000_000_000, suggested: suggested, kind: .folder,
                                   modified: now.addingTimeInterval(-400 * 86_400), decidedAt: now)
        }
        check(decision(.keep, suggested: .safe).isChoice && decision(.safe, suggested: .safe).isChoice
              && decision(.trash, suggested: nil).isChoice,
              "выбор — поменять предложенное или согласиться что-то сделать")
        check(!decision(.keep, suggested: .keep).isChoice && !decision(.keep, suggested: nil).isChoice,
              "«оставить», когда оставить и предлагалось (или неизвестно, что предлагалось), — не выбор")
        let passive = HabitModel(history: (1...5).map { decision(.keep, suggested: .keep, path: "/Users/q/Movies/\($0)") }, home: home)
        check(passive.isEmpty && passive.count == 0, "на согласии по умолчанию модель не учится")
        let active = HabitModel(history: (1...3).map { decision(.keep, suggested: .safe, path: "/Users/q/Movies/\($0)") }, home: home)
        check(active.count == 3 && active.predict(features("Movies/Новая"), allowed: [.safe, .keep])?.action == .keep,
              "на том, что вы поменяли, — учится")
    }

    section("Привычки: база") {
        let url = scratch.appendingPathComponent("decisions-v2/decisions.sqlite")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // База второй версии: решения без вида и даты, отпечатки уже есть.
        var raw: OpaquePointer?
        check(sqlite3_open(url.path, &raw) == SQLITE_OK, "база второй версии создаётся")
        let v2 = """
            CREATE TABLE decisions (id INTEGER PRIMARY KEY, path TEXT NOT NULL, action TEXT NOT NULL, bytes INTEGER NOT NULL, decided_at REAL NOT NULL);
            CREATE INDEX decisions_path ON decisions(path, decided_at);
            CREATE TABLE runs (id INTEGER PRIMARY KEY, started_at REAL NOT NULL, trashed_bytes INTEGER NOT NULL, moved_bytes INTEGER NOT NULL, added_to_backup INTEGER NOT NULL, failures INTEGER NOT NULL);
            CREATE TABLE fingerprints (path TEXT PRIMARY KEY, size INTEGER NOT NULL, modified REAL NOT NULL, inode INTEGER NOT NULL, edges TEXT, full TEXT, seen_at REAL NOT NULL);
            INSERT INTO decisions (path, action, bytes, decided_at) VALUES ('/Users/q/Movies/old', 'keep', 7, 10);
            INSERT INTO fingerprints VALUES ('/f', 1, 1, 1, 'e', 'f', 1);
            PRAGMA user_version = 2;
            """
        check(sqlite3_exec(raw, v2, nil, nil, nil) == SQLITE_OK, "в старой базе есть решение и отпечаток")
        sqlite3_close(raw)

        let store = try DecisionStore(url: url)
        let before = try store.history()
        check(before.count == 1 && before.first?.kind == nil && before.first?.modified == nil && before.first?.suggested == nil
              && before.first?.decidedAt == Date(timeIntervalSince1970: 10),
              "после обновления старое решение на месте, чего оно не знало — пусто")
        try store.record([
            DecisionStore.Decision(path: "/Users/q/Movies/a", action: .keep, bytes: 5, suggested: .safe, kind: .folder,
                                   modified: Date(timeIntervalSince1970: 1_000), decidedAt: Date(timeIntervalSince1970: 2_000)),
            DecisionStore.Decision(path: "/Users/q/Movies/a", action: .safe, bytes: 6, suggested: .safe, kind: .folder,
                                   modified: Date(timeIntervalSince1970: 1_500), decidedAt: Date(timeIntervalSince1970: 3_000)),
        ])
        let history = try store.history()
        let latest = history.first { $0.path == "/Users/q/Movies/a" }
        check(history.count == 2 && latest?.action == .safe && latest?.bytes == 6, "по каждому пути — одно, последнее решение")
        check(latest?.suggested == .safe && latest?.kind == .folder && latest?.modified == Date(timeIntervalSince1970: 1_500),
              "вид, дата изменения и предложенное сохраняются")
        check(try store.lastDecisions()["/Users/q/Movies/a"] == .safe, "«как в прошлый раз» видит новые записи")

        try store.recordRun(DecisionStore.Run(trashedBytes: 1, movedBytes: 2, addedToBackup: 0, failures: 0))
        try store.forgetDecisions()
        check(try store.history().isEmpty && store.lastDecisions().isEmpty, "решения забыты целиком")
        check(try store.lastRun() != nil && store.fingerprints()["/f"] != nil, "итоги разборов и отпечатки файлов остаются")

        var reader: OpaquePointer?
        sqlite3_open(url.path, &reader)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(reader, "PRAGMA user_version", -1, &statement, nil)
        sqlite3_step(statement)
        check(sqlite3_column_int(statement, 0) == 4, "версия схемы — последняя, 4")
        sqlite3_finalize(statement)
        sqlite3_close(reader)
    }
}
