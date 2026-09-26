import Foundation
import OffloadCore
import SQLite3

/// Поиск одинаковых файлов: что считается копией, какая остаётся и что сверяется перед удалением.
func checksDuplicates() {
    section("Дубликаты: поиск") {
        let rules = SafetyRules(home: scratch.appendingPathComponent("dup-home", isDirectory: true))
        let home = rules.home
        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        func put(_ data: Data, _ relative: String) throws {
            try fm.createDirectory(at: url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url(relative))
        }
        func bytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

        let size = 300_000
        let photo = bytes(size, seed: 1)
        try put(photo, "Downloads/photo.jpg")
        try put(photo, "Pictures/2019/photo.jpg")
        try put(photo, "Desktop/photo (1).jpg")
        // Тот же размер и те же края, другая середина: отличить может только полное сравнение.
        var middle = photo
        middle[size / 2] ^= 0xFF
        try put(middle, "Documents/almost.jpg")
        try fm.linkItem(at: url("Downloads/photo.jpg"), to: url("Documents/hardlink.jpg"))
        try fm.createSymbolicLink(at: url("Documents/link.jpg"), withDestinationURL: url("Downloads/photo.jpg"))
        try put(photo, "Documents/.hidden/photo.jpg")
        try put(photo, "Projects/app/assets/photo.jpg")
        try fm.createDirectory(at: url("Projects/app/.git"), withIntermediateDirectories: true)
        try put(photo, "Projects/site/node_modules/pkg/photo.jpg")
        try put(photo, "Downloads/Tool.app/Contents/Resources/photo.jpg")
        try put(bytes(1_000, seed: 2), "Downloads/small.txt")
        try put(bytes(1_000, seed: 2), "Documents/small.txt")

        var finder = DuplicateFinder()
        finder.minimumBytes = 100_000
        finder.edgeBytes = 4_096
        let roots = ["Downloads", "Desktop", "Documents", "Pictures", "Projects"].map { url($0) }
        let first = finder.find(in: roots, rules: rules)
        check(first.completed, "поиск закончен")
        check(first.groups.count == 1, "одна группа: копии фото; почти такие же и мелкие файлы — не дубликаты")
        let found = first.groups.first?.copies.map { String($0.url.path.dropFirst(home.path.count + 1)) } ?? []
        check(found == ["Desktop/photo (1).jpg", "Downloads/photo.jpg", "Pictures/2019/photo.jpg"],
              "копии фото — в Загрузках, на Рабочем столе и в Изображениях; скрытые папки, git-проекты, node_modules, пакеты, ссылки и второе имя того же файла копиями не считаются")
        check(first.groups.first?.bytes == Int64(size), "у группы размер одной копии")
        check(first.groups.first.map(DuplicateFinder.savings) == first.groups.first.map { $0.copies.map(\.allocated).sorted().dropLast().reduce(0, +) },
              "освободится всё, кроме одной копии")
        check(first.groups.first?.copies.allSatisfy { $0.verdict == .safe } == true, "у каждой копии решение правил по пути")
        check(first.readBytes > 0, "в первый раз файлы читаются")

        let known = Dictionary(uniqueKeysWithValues: first.fingerprints.map { ($0.path, $0) })
        let second = finder.find(in: roots, rules: rules, known: known)
        check(second.groups.map(\.id) == first.groups.map(\.id), "с отпечатками находится то же самое")
        check(second.readBytes == 0, "неизменившиеся файлы второй раз не читаются")

        // Файл поменяли, размер тот же: отпечаток больше не годится.
        try put(bytes(size, seed: 9), "Desktop/photo (1).jpg")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: url("Desktop/photo (1).jpg").path)
        let third = finder.find(in: roots, rules: rules, known: known)
        check(third.groups.first?.copies.count == 2, "изменившийся файл перечитан и из группы выпал")
        check(third.readBytes > 0 && third.readBytes < first.readBytes, "перечитан только он")

        var clones = finder
        let clonePath = url("Pictures/2019/photo.jpg").standardizedFileURL.path
        let originalPath = url("Downloads/photo.jpg").standardizedFileURL.path
        clones.contentIdentifier = { [clonePath, originalPath].contains($0.standardizedFileURL.path) ? 42 : nil }
        let cloned = clones.find(in: roots, rules: rules).groups.first
        check(cloned?.copies.filter(\.sharesData).count == 2, "клоны APFS помечены: удаление одного места не освободит")

        var cancelled = 0
        let stopped = finder.find(in: roots, rules: rules, isCancelled: { cancelled += 1; return cancelled > 3 })
        check(!stopped.completed && stopped.groups.isEmpty, "остановленный поиск ничего не выдаёт за итог")

        check(try DuplicateFinder.sameContent(url("Downloads/photo.jpg"), url("Pictures/2019/photo.jpg")),
              "одинаковые файлы совпадают байт в байт")
        check(!(try DuplicateFinder.sameContent(url("Downloads/photo.jpg"), url("Documents/almost.jpg"))),
              "различие в одном байте посередине находится")
        check(!(try DuplicateFinder.sameContent(url("Downloads/photo.jpg"), url("Documents/hardlink.jpg"))),
              "второе имя того же файла копией не считается")
        check(!(try DuplicateFinder.sameContent(url("Downloads/small.txt"), url("Downloads/photo.jpg"))), "разный размер — не копии")
        expectError("исчезнувший файл — ошибка, а не «совпало»") {
            _ = try DuplicateFinder.sameContent(url("Downloads/photo.jpg"), url("Downloads/нет такого.jpg"))
        }
    }

    section("Дубликаты: что остаётся и что удаляется") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let home = URL(fileURLWithPath: "/Users/q", isDirectory: true)
        let planner = CleanupPlanner(now: now, home: home)
        func copy(_ relative: String, daysAgo: Double = 10, verdict: Verdict = .safe, shares: Bool = false) -> DuplicateCopy {
            DuplicateCopy(url: home.appendingPathComponent(relative), allocated: 5_000_000,
                          modified: now.addingTimeInterval(-daysAgo * 86_400), created: now.addingTimeInterval(-daysAgo * 86_400),
                          verdict: verdict, sharesData: shares)
        }
        func group(_ copies: DuplicateCopy...) -> DuplicateGroup { DuplicateGroup(id: "h\(copies.count)", bytes: 5_000_000, copies: copies) }
        func names(_ list: [CleanupSuggestion]) -> [String] { list.map { String($0.id.dropFirst(home.path.count + 1)) } }

        let placed = planner.suggestions([], duplicates: [group(copy("Downloads/a.pdf", daysAgo: 400),
                                                                copy("Documents/Отчёты/a.pdf", daysAgo: 1))])
        check(names(placed) == ["Documents/Отчёты/a.pdf", "Downloads/a.pdf"], "остаётся копия на своём месте, а не в Загрузках — даже более новая")
        check(placed.map(\.action) == [.keep, .trash] && placed.allSatisfy { $0.duplicateGroup == "h2" },
              "лишняя копия — в Корзину, обе строки помечены группой")
        check(placed[1].allowed == [.trash, .keep], "лишнюю копию можно и оставить")

        let named = planner.suggestions([], duplicates: [group(copy("Downloads/a (1).pdf", daysAgo: 30),
                                                               copy("Downloads/a.pdf", daysAgo: 1))])
        check(names(named).first == "Downloads/a.pdf", "из двух в одной папке остаётся имя без «(1)»")
        check(CleanupPlanner.looksLikeCopy("Отчёт копия 2.pdf") && CleanupPlanner.looksLikeCopy("photo copy.jpg")
              && CleanupPlanner.looksLikeCopy("scan 2.pdf") && CleanupPlanner.looksLikeCopy("invoice-1.pdf")
              && !CleanupPlanner.looksLikeCopy("Отчёт 2019.pdf") && !CleanupPlanner.looksLikeCopy("a.pdf"),
              "имена копий узнаются, год в имени копией не считается")
        let older = planner.suggestions([], duplicates: [group(copy("Documents/b.pdf", daysAgo: 5), copy("Pictures/b.pdf", daysAgo: 50))])
        check(names(older).first == "Pictures/b.pdf", "при прочих равных остаётся копия, появившаяся раньше")

        let music = planner.suggestions([], duplicates: [group(copy("Downloads/song.m4a", daysAgo: 400),
                                                               copy("Music/Music/Media.localized/Music/A/song.m4a", daysAgo: 1))])
        check(names(music).first?.hasPrefix("Music/Music/") == true && music.first?.allowed == [.keep],
              "копия в медиатеке «Музыки» остаётся, и удалить её нельзя вовсе")
        check(music.last?.action == .trash, "лишней становится копия в Загрузках")
        check(planner.suggestions([], duplicates: [group(copy("Music/Music/Media.localized/a.m4a"),
                                                         copy("Music/iTunes/iTunes Media/a.m4a"))]).isEmpty,
              "группа, где удалить нельзя ни одну копию, не показывается")
        check(planner.suggestions([], duplicates: [group(copy("Documents/c.pdf", shares: true), copy("Documents/c копия.pdf", shares: true))]).isEmpty,
              "клоны APFS не предлагаются: места их удаление не освободит")
        let blocked = planner.suggestions([], duplicates: [group(copy("Documents/d.bin"), copy("Documents/x.utm/d.bin", verdict: .blocked("пакет")))])
        check(blocked.first(where: { $0.id.contains(".utm") })?.allowed == [.keep], "копию в запрещённом месте удалить нельзя")

        // Строки разбора и группы не пересекаются.
        func top(_ relative: String, gb: Double, daysAgo: Double, directory: Bool = false) -> CleanupObservation {
            CleanupObservation(url: home.appendingPathComponent(relative), bytes: Int64(gb * 1_000_000_000),
                               modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: directory, verdict: .safe)
        }
        let film = group(copy("Movies/film.mkv", daysAgo: 400), copy("Downloads/film.mkv", daysAgo: 300))
        let merged = planner.suggestions([top("Movies/film.mkv", gb: 4, daysAgo: 400), top("Downloads/film.mkv", gb: 4, daysAgo: 300)],
                                         duplicates: [film])
        check(merged.count == 2 && merged.allSatisfy { $0.duplicateGroup != nil }, "файл-копия показывается только в своей группе")
        check(merged.first?.action == .safe && merged.first?.allowed == [.trash, .safe, .keep],
              "большая старая копия, которая остаётся, по-прежнему предлагается в сейф")
        check(merged.last?.action == .trash && merged.last?.allowed == [.trash, .safe, .keep],
              "лишнюю копию не везут в сейф, а удаляют")
        let installers = planner.suggestions([top("Downloads/app.dmg", gb: 0.5, daysAgo: 30), top("Desktop/app.dmg", gb: 0.5, daysAgo: 30)],
                                             duplicates: [group(copy("Downloads/app.dmg"), copy("Desktop/app.dmg"))])
        check(installers.map(\.action) == [.trash, .trash] && installers.allSatisfy { $0.duplicateGroup == nil },
              "старые установщики уходят по своему правилу, группа им не нужна")

        var remembering = planner
        remembering.memory = [home.appendingPathComponent("Downloads/a.pdf").path: .keep]
        let kept = remembering.suggestions([], duplicates: [group(copy("Downloads/a.pdf"), copy("Documents/a.pdf"))])
        check(kept.last?.action == .keep && kept.last?.learned == true, "прошлое «оставить» для копии помнится")
        remembering.memory = [home.appendingPathComponent("Downloads/a.pdf").path: .trash,
                              home.appendingPathComponent("Documents/a.pdf").path: .trash]
        let both = remembering.suggestions([], duplicates: [group(copy("Downloads/a.pdf"), copy("Documents/a.pdf"))])
        check(both.contains { $0.action != .trash }, "прошлые решения не отправят в Корзину все копии разом")

        // Выбор человека: последнюю остающуюся копию удалить нельзя, сверка — с остающейся.
        let pair = placed
        func effective(_ choices: [String: CleanupAction]) -> (CleanupSuggestion) -> CleanupAction { { choices[$0.id] ?? $0.action } }
        check(CleanupPlanner.options(for: pair[0], in: pair, effective: effective([:])) == [.keep],
              "у единственной остающейся копии Корзины в выборе нет")
        check(CleanupPlanner.options(for: pair[1], in: pair, effective: effective([:])) == [.trash, .keep], "у лишней — есть")
        let swapped = effective([pair[1].id: .keep])
        check(CleanupPlanner.options(for: pair[0], in: pair, effective: swapped).contains(.trash),
              "оставили другую копию — эту теперь можно удалить")
        check(CleanupPlanner.reference(for: pair[1], in: pair, effective: effective([:]))?.id == pair[0].id,
              "удаляемая копия сверяется с остающейся")
        check(CleanupPlanner.reference(for: pair[1], in: pair, effective: effective([pair[0].id: .trash])) == nil,
              "если не остаётся ни одной копии, сверять не с чем — удалять нельзя")

        let folder = CleanupSuggestion(url: home.appendingPathComponent("Documents"), bytes: 1, modified: nil, isDirectory: true,
                                       action: .safe, reason: "", allowed: [.safe, .keep], learned: false, cautions: [])
        let inside = CleanupPlanner.container(of: placed[0], in: [folder] + placed)
        check(inside?.id == folder.id, "видно, в какой папке из списка лежит копия")
        check(CleanupPlanner.container(of: placed[1], in: [folder] + placed) == nil, "копия в Загрузках ни в какой папке списка не лежит")
    }

    section("Дубликаты: отпечатки в базе") {
        let url = scratch.appendingPathComponent("decisions-v1/decisions.sqlite")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // База первой версии, как её оставил прошлый Offload.
        var raw: OpaquePointer?
        check(sqlite3_open(url.path, &raw) == SQLITE_OK, "старая база создаётся")
        let v1 = """
            CREATE TABLE decisions (id INTEGER PRIMARY KEY, path TEXT NOT NULL, action TEXT NOT NULL, bytes INTEGER NOT NULL, decided_at REAL NOT NULL);
            CREATE INDEX decisions_path ON decisions(path, decided_at);
            CREATE TABLE runs (id INTEGER PRIMARY KEY, started_at REAL NOT NULL, trashed_bytes INTEGER NOT NULL, moved_bytes INTEGER NOT NULL, added_to_backup INTEGER NOT NULL, failures INTEGER NOT NULL);
            INSERT INTO decisions (path, action, bytes, decided_at) VALUES ('/old', 'keep', 1, 1);
            PRAGMA user_version = 1;
            """
        check(sqlite3_exec(raw, v1, nil, nil, nil) == SQLITE_OK, "в старой базе есть решение")
        sqlite3_close(raw)

        let store = try DecisionStore(url: url)
        check(try store.lastDecisions() == ["/old": .keep], "после обновления прежние решения на месте")
        let prints = [Fingerprint(path: "/a", size: 10, modified: 1.5, inode: 7, edges: "e", full: "f"),
                      Fingerprint(path: "/b", size: 20, modified: 2.5, inode: 8, edges: "e2", full: nil)]
        try store.saveFingerprints(prints, at: Date(timeIntervalSince1970: 100))
        check(try store.fingerprints() == ["/a": prints[0], "/b": prints[1]], "отпечатки сохраняются, в том числе без полного хеша")
        try store.saveFingerprints([Fingerprint(path: "/a", size: 11, modified: 3, inode: 7, edges: "e3", full: "f3")],
                                   at: Date(timeIntervalSince1970: 200))
        check(try store.fingerprints()["/a"]?.size == 11, "новый отпечаток того же файла заменяет старый")
        try store.forgetFingerprints(seenBefore: Date(timeIntervalSince1970: 150))
        check(try store.fingerprints().keys.sorted() == ["/a"], "отпечатки, которых последний поиск не касался, забываются")

        let reopened = try DecisionStore(url: url)
        check(try reopened.fingerprints()["/a"]?.full == "f3", "отпечатки переживают перезапуск")
        var reader: OpaquePointer?
        sqlite3_open(url.path, &reader)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(reader, "PRAGMA user_version", -1, &statement, nil)
        sqlite3_step(statement)
        check(sqlite3_column_int(statement, 0) == 2, "версия схемы — 2")
        sqlite3_finalize(statement)
        sqlite3_close(reader)
    }
}
