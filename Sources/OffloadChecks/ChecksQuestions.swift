import Foundation
import OffloadCore

// Разбор без флажков: найденное раскладывается по вопросам «да или нет».
// Вызывается из main.swift; check/section берутся оттуда же — это один модуль.

func checksQuestions() {
    section("Разбор: вопросы вместо флажков") {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let home = URL(fileURLWithPath: "/Users/q", isDirectory: true)
        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
        func item(_ relative: String, gb: Double, daysAgo: Double, directory: Bool = true, verdict: Verdict = .safe,
                  project: Bool = false) -> CleanupObservation {
            CleanupObservation(url: home.appendingPathComponent(relative), bytes: Int64(gb * 1_000_000_000),
                               modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: directory,
                               verdict: verdict, isProject: project)
        }
        func copy(_ relative: String, daysAgo: Double) -> DuplicateCopy {
            let date = now.addingTimeInterval(-daysAgo * 86_400)
            return DuplicateCopy(url: home.appendingPathComponent(relative), allocated: 2_000_000_000, modified: date, created: date)
        }
        let library = Verdict.blocked("Данные приложений")
        let regenerable = [path("Library/Developer/Xcode/DerivedData"): CleanupPlanner.regenerableLocations[0].reason,
                           path("Library/Caches/Google/Chrome"): "Кеш Chrome — страницы подгрузятся снова."]
        let planner = CleanupPlanner(now: now, home: home, regenerable: regenerable,
                                     memory: [path("Downloads/Старый.pkg"): .keep],
                                     busy: CleanupPlanner.busy(home: home, running: ["com.google.Chrome": "Google Chrome"]))
        let suggestions = planner.suggestions([
            item("Library/Developer/Xcode/DerivedData", gb: 20, daysAgo: 1, verdict: library),
            item("Library/Caches/Google/Chrome", gb: 2, daysAgo: 0, verdict: library),
            item("Downloads/Figma.dmg", gb: 0.3, daysAgo: 20, directory: false),
            item("Downloads/Старый.pkg", gb: 0.5, daysAgo: 60, directory: false),
            item("Movies/Съёмки 2019", gb: 80, daysAgo: 500),
            item("Movies/Монтаж", gb: 90, daysAgo: 3),
            item("Projects/app", gb: 2, daysAgo: 200, project: true),
        ], duplicates: [
            DuplicateGroup(id: "video", bytes: 2_000_000_000, copies: [
                copy("Movies/Отпуск.mov", daysAgo: 300), copy("Downloads/Отпуск.mov", daysAgo: 40),
                copy("Desktop/Отпуск (1).mov", daysAgo: 12)]),
            // Лишняя копия внутри папки, которую можно убрать в сейф, едет вместе с папкой.
            DuplicateGroup(id: "inside", bytes: 2_000_000_000, copies: [
                copy("Documents/Отчёт.pdf", daysAgo: 600), copy("Movies/Съёмки 2019/Отчёт.pdf", daysAgo: 500)]),
        ])
        let docker = DockerUsage(images: DockerUsage.Part(count: 20, active: 3, bytes: 12_000_000_000, reclaimable: 10_200_000_000),
                                 containers: DockerUsage.Part(count: 5, active: 1, bytes: 1_200_000, reclaimable: 1_100_000),
                                 volumes: DockerUsage.Part(count: 12, active: 4, bytes: 31_000_000_000, reclaimable: 20_000_000_000),
                                 buildCache: DockerUsage.Part(count: 120, active: 0, bytes: 5_600_000_000, reclaimable: 5_600_000_000))
        let questions = CleanupQuestions.build(suggestions, docker: docker)
        func question(_ kind: CleanupQuestion.Kind) -> CleanupQuestion? { questions.first { $0.kind == kind } }
        func names(_ kind: CleanupQuestion.Kind) -> [String] { question(kind)?.items.map { $0.url.lastPathComponent } ?? [] }

        check(questions.map(\.kind) == [.module(.junk), .docker, .module(.duplicates), .module(.installers), .module(.safe),
                                        .module(.projects)],
              "порядок: сначала то, что пересоздаётся само, потом личное; машин UTM среди вопросов нет: \(questions.map(\.kind))")

        let junk = question(.module(.junk))
        check(names(.module(.junk)) == ["DerivedData"] && junk?.bytes == 20_000_000_000,
              "в вопросе о мусоре — только то, что можно удалить сейчас")
        check(junk?.notes.contains { $0.contains("Google Chrome") } == true, "кеш открытой программы в вопрос не входит, и сказано почему")
        check(junk?.labels == ["Промежуточные файлы сборки Xcode"], "мусор назван по-человечески, а не именем папки: \(junk?.labels ?? [])")

        let dockerQuestion = question(.docker)
        check(dockerQuestion?.docker == [.buildCache: 5_600_000_000, .danglingImages: 0] && dockerQuestion?.bytes == 5_600_000_000,
              "Docker: кеш сборки и образы без имени")
        check(dockerQuestion?.docker[.images] == nil,
              "все неиспользуемые образы (--all) в вопрос не входят: собранный вами образ не скачать")
        check(dockerQuestion?.docker[.containers] == nil, "остановленные контейнеры в вопрос о Docker не входят: в них бывают данные")
        check(!CleanupQuestions.build([], docker: DockerUsage(buildCache: DockerUsage.Part(count: 1, active: 0, bytes: 50_000_000,
                                                                                            reclaimable: 50_000_000))).contains { $0.kind == .docker },
              "о Docker, который отдаст меньше 100 МБ, не спрашиваю")

        let duplicates = question(.module(.duplicates))
        check(names(.module(.duplicates)).sorted() == ["Отпуск (1).mov", "Отпуск.mov"]
              && duplicates?.items.allSatisfy { !$0.url.path.hasPrefix(path("Movies")) } == true,
              "лишние копии — те, что в Загрузках и на Рабочем столе; копия на своём месте остаётся")
        check(duplicates?.keepers.map(\.url.path) == [path("Movies/Отпуск.mov")], "с чем сверять перед удалением — копия, которая остаётся")
        check(duplicates?.items.contains { $0.url.path.hasPrefix(path("Movies/Съёмки 2019") + "/") } == false,
              "копия внутри папки, которую можно убрать в сейф, в вопрос о копиях не входит — поедет вместе с папкой")
        check(duplicates?.bytes == 4_000_000_000, "освободится ровно столько, сколько занимают лишние копии")

        check(names(.module(.installers)) == ["Figma.dmg"], "старый установщик — в вопросе, а тот, что вы вернули из Корзины, — нет")
        check(names(.module(.safe)) == ["Съёмки 2019"], "в сейф — большое и давно не менявшееся; то, что меняли на днях, не спрашиваю")
        check(names(.module(.projects)) == ["app"] && question(.module(.projects))?.bytes == 0,
              "проекты — в бэкап; места на Mac это не освобождает")
        check(!questions.contains { $0.items.contains { $0.url.lastPathComponent == "Монтаж" } },
              "то, что трогать незачем, ни в один вопрос не попадает")

        check(questions.filter { !$0.answeredTogether }.map(\.kind) == [.module(.installers)],
              "«Разрешить всё» не удаляет установщики: только отдельным «да» на их вопрос")
        check(questions.allSatisfy { $0.kind == .module(.projects) || $0.bytes > 0 }, "в каждом вопросе, кроме бэкапа, есть что освободить")
        check(CleanupQuestions.build([]).isEmpty, "нечего спрашивать — нет и вопросов")
    }
}
