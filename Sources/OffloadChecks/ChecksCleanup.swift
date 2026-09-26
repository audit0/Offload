import Foundation
import OffloadCore

/// Разбор Mac одной кнопкой: что предлагается и что запоминается из решений человека.
func checksCleanup() {
    section("Разбор: предложения") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let home = URL(fileURLWithPath: "/Users/q", isDirectory: true)
        func item(_ relative: String, gb: Double, daysAgo: Double?, directory: Bool = true, verdict: Verdict = .safe,
                  project: Bool = false, inBackup: Bool = false) -> CleanupObservation {
            CleanupObservation(url: home.appendingPathComponent(relative), bytes: Int64(gb * 1_000_000_000),
                               modified: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, isDirectory: directory,
                               verdict: verdict, isProject: project, inBackup: inBackup)
        }
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        let planner = CleanupPlanner(now: now, regenerable: [derived: "кеш сборки"])

        let cache = planner.suggest(item("Library/Developer/Xcode/DerivedData", gb: 20, daysAgo: 1,
                                         verdict: .blocked("Данные приложений")))
        check(cache.action == .trash, "кеш сборки Xcode предлагается в Корзину, хотя ~/Library переносить нельзя")
        check(cache.allowed == [.trash, .keep], "кеш можно только удалить или оставить — ни в сейф, ни в бэкап")

        let installer = planner.suggest(item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 20, directory: false))
        check(installer.action == .keep && installer.allowed.contains(.trash),
              "старый установщик сам в Корзину не предлагается, но выбрать её можно: .dmg бывает и личным")
        let encrypted = planner.suggest(CleanupObservation(
            url: home.appendingPathComponent("Downloads/Документы.dmg"), bytes: 2_000_000_000,
            modified: now.addingTimeInterval(-400 * 86_400), isDirectory: false, verdict: .safe, isEncryptedImage: true))
        check(!encrypted.allowed.contains(.trash), "зашифрованный .dmg — личные данные: удалить из разбора нельзя")
        check(encrypted.action == .safe, "большой старый зашифрованный образ — в сейф, как любой личный файл")
        let iso = planner.suggest(item("Downloads/ubuntu.iso", gb: 5, daysAgo: 20, directory: false))
        check(!iso.allowed.contains(.trash), ".iso не установщик: к нему бывает подключена виртуальная машина")
        let learnedTrash = CleanupPlanner(now: now, memory: [home.appendingPathComponent("Downloads/Figma.dmg").path: .trash])
            .suggest(item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 20, directory: false))
        check(learnedTrash.action == .trash && learnedTrash.learned, "если в прошлый раз установщик удалили — предлагается то же")
        let fresh = planner.suggest(item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 2, directory: false))
        check(!fresh.allowed.contains(.trash), "установщик, скачанный на днях, удалить не предлагается: его могли ещё не поставить")
        let video = planner.suggest(item("Downloads/film.mkv", gb: 3, daysAgo: 400, directory: false))
        check(!video.allowed.contains(.trash), "личный файл удалить нельзя вовсе — только в сейф или оставить")
        check(video.action == .safe, "большой и давно не менявшийся файл — в сейф")

        let old = planner.suggest(item("Movies/Съёмки 2019", gb: 80, daysAgo: 500))
        check(old.action == .safe && old.allowed.contains(.backup), "большая старая папка — в сейф, бэкап тоже можно выбрать")
        let recent = planner.suggest(item("Movies/Монтаж", gb: 80, daysAgo: 3))
        check(recent.action == .keep, "папка, которую меняли на днях, остаётся на месте")
        let project = planner.suggest(item("Projects/app", gb: 2, daysAgo: 200, project: true))
        check(project.action == .backup, "проект с git предлагается в бэкап, а не в сейф")
        let backedUp = planner.suggest(item("Projects/app", gb: 2, daysAgo: 200, project: true, inBackup: true))
        check(!backedUp.allowed.contains(.backup), "то, что уже в бэкапе, второй раз туда не предлагается")
        let library = planner.suggest(item("Pictures/Photos Library.photoslibrary", gb: 60, daysAgo: 500,
                                           verdict: .blocked("медиатека")))
        check(library.action == .keep && library.allowed == [.keep] && library.reason == "медиатека",
              "медиатеку нельзя ни удалить, ни перенести — и сказано почему")
        let caution = planner.suggest(item("Projects/old", gb: 5, daysAgo: 400, verdict: .caution(["оговорка"])))
        check(caution.action == .keep && caution.allowed.contains(.safe) && caution.cautions == ["оговорка"],
              "с оговорками — само не предлагается, но выбрать можно, и оговорка видна")

        var learning = planner
        learning.memory = [home.appendingPathComponent("Movies/Съёмки 2019").path: .keep,
                           home.appendingPathComponent("Movies/Монтаж").path: .trash]
        let remembered = learning.suggest(item("Movies/Съёмки 2019", gb: 80, daysAgo: 500))
        check(remembered.action == .keep && remembered.learned, "прошлое решение «оставить» побеждает правило")
        let impossible = learning.suggest(item("Movies/Монтаж", gb: 80, daysAgo: 3))
        check(impossible.action == .keep && !impossible.learned,
              "прошлое решение, которое теперь недопустимо (удалить личную папку), не применяется")

        let list = planner.suggestions([
            item("Downloads/small", gb: 0.01, daysAgo: 500),
            item("Movies/Съёмки 2019", gb: 80, daysAgo: 500),
            item("Library/Developer/Xcode/DerivedData", gb: 2, daysAgo: 1, verdict: .blocked("Данные приложений")),
            item("Movies/Монтаж", gb: 90, daysAgo: 3),
        ])
        check(list.map(\.action) == [.trash, .safe] && list.map(\.module) == [.junk, .safe],
              "сначала мусор, потом сейф; мелочь и то, что трогать незачем, в итоги не попадают")
    }

    section("Разбор: плитки и что отмечено сразу") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let home = URL(fileURLWithPath: "/Users/q", isDirectory: true)
        func item(_ relative: String, gb: Double, daysAgo: Double, directory: Bool = true, verdict: Verdict = .safe,
                  project: Bool = false) -> CleanupObservation {
            CleanupObservation(url: home.appendingPathComponent(relative), bytes: Int64(gb * 1_000_000_000),
                               modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: directory, verdict: verdict,
                               isProject: project)
        }
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        let chrome = home.appendingPathComponent("Library/Caches/Google/Chrome").path
        let planner = CleanupPlanner(now: now, home: home, regenerable: [derived: "кеш сборки", chrome: "кеш Chrome"])

        let cache = planner.suggest(item("Library/Developer/Xcode/DerivedData", gb: 5, daysAgo: 1, verdict: .blocked("Данные приложений")))
        check(cache.module == .junk && cache.preselected && cache.defaultChoice == .trash,
              "мусор — плитка «Мусор», отмечен сразу: программы создадут его заново")
        let film = planner.suggest(item("Movies/Съёмки 2019", gb: 80, daysAgo: 500))
        check(film.module == .safe && film.action == .safe && !film.preselected && film.defaultChoice == .keep,
              "крупное и старое — в плитке сейфа, но само не отмечается: личное решаете вы")
        let project = planner.suggest(item("Projects/app", gb: 2, daysAgo: 200, project: true))
        check(project.module == .projects && project.preselected, "проект без бэкапа отмечен сразу: добавление в бэкап ничего не удаляет")
        let installer = planner.suggest(item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 20, directory: false))
        check(installer.module == .installers && !installer.preselected && installer.defaultChoice == .keep,
              "старый установщик — в своей плитке, неотмеченным")
        check(planner.suggest(item("Movies/Монтаж", gb: 80, daysAgo: 3)).module == nil, "то, чем пользуются, ни в какую плитку не попадает")

        var remembering = planner
        remembering.memory = [home.appendingPathComponent("Movies/Съёмки 2019").path: .safe,
                              home.appendingPathComponent("Downloads/Figma.dmg").path: .trash,
                              home.appendingPathComponent("Projects/app").path: .keep]
        check(remembering.suggest(item("Movies/Съёмки 2019", gb: 80, daysAgo: 500)).preselected,
              "в прошлый раз вы убрали это в сейф — теперь отмечено сразу")
        check(remembering.suggest(item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 20, directory: false)).preselected,
              "установщик, который вы удаляли в прошлый раз, отмечен")
        let keptProject = remembering.suggest(item("Projects/app", gb: 2, daysAgo: 200, project: true))
        check(keptProject.module == .projects && !keptProject.preselected && keptProject.learned,
              "проект, который вы в прошлый раз не стали добавлять, остаётся в своей плитке неотмеченным")

        var busy = planner
        busy.busy = CleanupPlanner.busy(home: home, running: ["com.google.Chrome": "Google Chrome", "com.apple.Safari": "Safari"])
        busy.memory = [chrome: .trash]
        let open = busy.suggest(item("Library/Caches/Google/Chrome", gb: 1, daysAgo: 1, verdict: .blocked("Данные приложений")))
        check(open.module == .junk && !open.preselected && open.allowed.contains(.trash) && open.reason.contains("Google Chrome"),
              "кеш открытой программы не отмечается, даже если его удаляли в прошлый раз, — и сказано почему")
        check(busy.suggest(item("Library/Developer/Xcode/DerivedData", gb: 5, daysAgo: 1, verdict: .blocked("Данные приложений"))).preselected,
              "кеши закрытых программ отмечены как обычно")
        let jetbrains = CleanupPlanner.busy(home: home, running: ["com.jetbrains.intellij": "IntelliJ IDEA"])
        check(jetbrains.keys.contains(home.appendingPathComponent("Library/Caches/JetBrains").path) && jetbrains.count == 1,
              "любая среда JetBrains держит общий кеш JetBrains, и только его")
        check(CleanupPlanner.busy(home: home, running: [:]).isEmpty, "ничего не открыто — ничего не занято")

        var ignoring = planner
        ignoring.ignored = [home.appendingPathComponent("Movies").path, chrome]
        let visible = ignoring.suggestions([item("Movies/Съёмки 2019", gb: 80, daysAgo: 500),
                                            item("Library/Caches/Google/Chrome", gb: 1, daysAgo: 1, verdict: .blocked("Данные приложений")),
                                            item("Documents/Архив", gb: 20, daysAgo: 500)])
        check(visible.map { String($0.id.dropFirst(home.path.count + 1)) } == ["Documents/Архив"],
              "то, что вы просили не предлагать, — и всё внутри такой папки — в итоги не попадает")
        check(ignoring.isIgnored(home.appendingPathComponent("Movies/a/b.mov").path) && !ignoring.isIgnored(home.appendingPathComponent("Moviesx").path),
              "не предлагать папку — значит и всё внутри неё, но не соседей с похожим именем")

        let fake = scratch.appendingPathComponent("home-regenerable", isDirectory: true)
        for relative in [".gradle/caches", "Library/Caches/Google/Chrome", "Library/Caches/JetBrains"] {
            try fm.createDirectory(at: fake.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        check(Set(CleanupPlanner.regenerable(home: fake).keys) == Set([".gradle/caches", "Library/Caches/Google/Chrome", "Library/Caches/JetBrains"]
            .map { fake.appendingPathComponent($0, isDirectory: true).path }), "кеши Gradle, Chrome и JetBrains находятся, если они есть")
    }

    section("Разбор: база решений") {
        let url = scratch.appendingPathComponent("decisions/decisions.sqlite")
        do {
            let store = try DecisionStore(url: url)
            try store.record([(path: "/a", action: .keep, bytes: 10), (path: "/b", action: .safe, bytes: 20)],
                             at: Date(timeIntervalSince1970: 100))
            try store.record([(path: "/a", action: .backup, bytes: 10)], at: Date(timeIntervalSince1970: 200))
            try store.recordRun(DecisionStore.Run(date: Date(timeIntervalSince1970: 200), trashedBytes: 5, movedBytes: 20,
                                                  addedToBackup: 1, failures: 0))
            let decisions = try store.lastDecisions()
            check(decisions == ["/a": .backup, "/b": .safe], "по каждому пути помнится последнее решение")
            check(try store.counts(for: "/a") == [.keep: 1, .backup: 1], "считается, сколько раз что выбирали")
        }
        let reopened = try DecisionStore(url: url)
        check(try reopened.lastDecisions()["/a"] == .backup, "решения переживают перезапуск программы")
        check(try reopened.lastRun()?.movedBytes == 20, "итог последнего разбора сохранён")
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "файл базы читает только владелец")

        let tricky = "/Users/q/Мои «папки»/it's; DROP TABLE decisions;--"
        try reopened.record([(path: tricky, action: .keep, bytes: 1)])
        check(try reopened.lastDecisions()[tricky] == .keep, "кавычки и точки с запятой в пути — просто текст, не команды")

        let broken = scratch.appendingPathComponent("decisions/broken.sqlite")
        try "это не база".write(to: broken, atomically: true, encoding: .utf8)
        expectError("испорченный файл базы — понятная ошибка, а не падение") { _ = try DecisionStore(url: broken) }

        let long = try DecisionStore(url: nil)
        for index in 0..<(DecisionStore.decisionsPerPath + 5) {
            try long.record([(path: "/often", action: index.isMultiple(of: 2) ? .keep : .safe, bytes: 1)],
                            at: Date(timeIntervalSince1970: Double(1000 + index)))
        }
        check(try long.counts(for: "/often").values.reduce(0, +) == DecisionStore.decisionsPerPath,
              "по одному пути хранятся только последние решения — база не растёт без конца")
        check(try long.lastDecisions()["/often"] == .keep, "последнее решение при этом не теряется")

        let memory = try DecisionStore(url: nil)
        try memory.record([(path: "/x", action: .trash, bytes: 1)])
        check(try memory.lastDecisions() == ["/x": .trash], "база в памяти работает и ничего не пишет на диск")
        check(try memory.lastRun() == nil, "разборов ещё не было — итога нет")

        try reopened.ignore("/Users/q/Movies", at: Date(timeIntervalSince1970: 10))
        try reopened.ignore("/Users/q/VM «Ubuntu»; DROP", at: Date(timeIntervalSince1970: 20))
        try reopened.ignore("/Users/q/Movies", at: Date(timeIntervalSince1970: 30))
        check(try DecisionStore(url: url).ignoredPaths() == ["/Users/q/Movies", "/Users/q/VM «Ubuntu»; DROP"],
              "«не предлагать» переживает перезапуск, повтор не дублирует, сначала недавнее")
        try reopened.unignore("/Users/q/Movies")
        check(try reopened.ignoredPaths() == ["/Users/q/VM «Ubuntu»; DROP"], "вернуть в разбор можно")
        try reopened.forgetDecisions()
        check(try reopened.ignoredPaths().count == 1, "«Забыть мои решения» не трогает то, что вы просили не предлагать")
    }
}

/// Зашифрованный .dmg разбор узнаёт без пароля и без системных окон.
func checksCleanupImages() throws {
    let folder = scratch.appendingPathComponent("cleanup-images", isDirectory: true)
    try fm.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
    try write("данные", to: folder.appendingPathComponent("src/a.txt"))
    let encrypted = folder.appendingPathComponent("личное.dmg"), plain = folder.appendingPathComponent("Установщик.dmg")
    _ = try Runner.check("hdiutil", ["create", "-quiet", "-encryption", "AES-256", "-stdinpass", "-format", "UDZO",
                                     "-srcfolder", folder.appendingPathComponent("src").path, encrypted.path],
                         stdin: Data("Проверка-пароля-2026\u{0}".utf8), timeout: 120)
    _ = try Runner.check("hdiutil", ["create", "-quiet", "-format", "UDZO",
                                     "-srcfolder", folder.appendingPathComponent("src").path, plain.path], timeout: 120)
    check(SecretsVault.encryptionInfo(of: encrypted)?.encrypted == true, "зашифрованный .dmg распознаётся без пароля")
    check(SecretsVault.encryptionInfo(of: plain)?.encrypted == false, "обычный .dmg — не зашифрован")
}
