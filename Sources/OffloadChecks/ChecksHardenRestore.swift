import Darwin
import Foundation
import OffloadCore

// Проверки возврата на настоящих дисковых образах: ловушка со ссылкой в автозапуск,
// .DS_Store полным кругом, оговорки сверки, трудные имена и чужие остатки копирования.
// Пропускаются при OFFLOAD_SKIP_INTEGRATION=1 — как и остальные проверки с hdiutil.

/// Создаёт образ, подключает его и отдаёт точку монтирования. Отсоединяет вызывающий.
private func hardenMount(_ name: String, fs: String, volumeName: String, sizeMB: Int = 2048) throws -> URL {
    let image = scratch.appendingPathComponent(name)
    try Runner.check("hdiutil", ["create", "-size", "\(sizeMB)m", "-type", "SPARSE", "-fs", fs,
                                 "-volname", volumeName, "-quiet", image.path], timeout: 180)
    guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path],
                                                                   timeout: 120).stdout) else {
        throw CopyError.unreadable(image.path)
    }
    return mount
}

func checksHardenRestore() {
    guard env["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Возврат: ловушки, .DS_Store, имена и остатки — пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }

    section("Возврат: путь через подложенную ссылку в автозапуск") {
        // Журнал лежит на внешнем диске, и записать в него может кто угодно. Опасна не сама
        // запись, а возврат по ней: он создаёт недостающие каталоги и кладёт туда содержимое
        // архива. Путь «Documents/Фото/old/LaunchAgents/…», где old — ссылка на ~/Library,
        // до конца не существует, и Foundation ссылку в нём не разворачивает.
        let mount = try hardenMount("harden-trap.sparseimage", fs: "ExFAT", volumeName: "OFFTRAP")
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        let rules = SafetyRules(home: scratch.appendingPathComponent("home-trap", isDirectory: true))
        let mover = SafeMover(rules: rules)

        let agents = rules.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let photos = rules.home.appendingPathComponent("Documents/Фото", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: photos.appendingPathComponent("old").path,
                                  withDestinationPath: rules.home.appendingPathComponent("Library").path)

        // Архив настоящий и лежит на диске: если проверка пути отвалится, возврату будет что записать.
        let archived = mount.appendingPathComponent("Offload/Documents/Фото/old/LaunchAgents/com.evil", isDirectory: true)
        try write("<plist>вредонос</plist>", to: archived.appendingPathComponent("com.evil.plist"))
        let trap = MoveRecord(originalPath: photos.appendingPathComponent("old/LaunchAgents/com.evil").path,
                              archivedPath: archived.path, volumeName: "OFFTRAP", files: 1, bytes: 20,
                              originalRemoved: true)
        expectError("возврат по записи журнала через ссылку в ~/Library отклоняется",
                    { _ = try mover.restore(trap, deleteArchive: false) },
                    matching: { if case MoveError.unsafeRecord = $0 { return true }; return false })
        let inAgents = (try? fm.contentsOfDirectory(atPath: agents.path)) ?? []
        check(inAgents.isEmpty, "в ~/Library/LaunchAgents ничего не появилось: \(inAgents)")

        // Тот же архив по честному пути обязан вернуться: иначе проверка выше доказывала бы
        // только то, что возврат не работает вообще.
        let honest = MoveRecord(originalPath: photos.appendingPathComponent("старое").path, archivedPath: archived.path,
                                volumeName: "OFFTRAP", files: 1, bytes: 20, originalRemoved: true)
        let done = try mover.restore(honest, deleteArchive: false)
        check(done.record.restored && fm.fileExists(atPath: photos.appendingPathComponent("старое/com.evil.plist").path),
              "тот же архив по пути без ссылок возвращается")
    }

    section("Возврат: .DS_Store уезжает в архив и возвращается") {
        // В .DS_Store лежит разложенный человеком вид окна и положение иконок. Оригинал после
        // переноса удаляется, поэтому не скопировать .DS_Store — значит его потерять.
        // Одновременно Finder пишет его в любой момент, в том числе между планом и переносом,
        // и это не должно срывать уже начатый перенос.
        let mount = try hardenMount("harden-ds.sparseimage", fs: "ExFAT", volumeName: "OFFDS")
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard let volume = Volumes.info(for: mount) else { throw CopyError.unreadable(mount.path) }
        let rules = SafetyRules(home: scratch.appendingPathComponent("home-ds", isDirectory: true))
        let mover = SafeMover(rules: rules)

        let source = rules.home.appendingPathComponent("Downloads/галерея", isDirectory: true)
        try write("снимок", to: source.appendingPathComponent("фото.jpg"))
        try write("текст", to: source.appendingPathComponent("вложенная/файл.txt"))
        try write("вид вложенной папки", to: source.appendingPathComponent("вложенная/.DS_Store"))

        let plan = mover.plan(source: source, volume: volume)
        // Человек открыл папку в Finder уже после проверки, и тот записал свой .DS_Store.
        try write("вид корневой папки", to: source.appendingPathComponent(".DS_Store"))
        let record = try mover.execute(plan, deleteOriginal: true, acceptCautions: true)
        check(!fm.fileExists(atPath: source.path), "(а) .DS_Store, появившийся после проверки, перенос не сорвал")

        let target = URL(fileURLWithPath: record.archivedPath)
        check(fm.fileExists(atPath: target.appendingPathComponent("вложенная/.DS_Store").path),
              "(б) .DS_Store вложенной папки уехал в архив, а не пропал вместе с оригиналом")
        check(fm.fileExists(atPath: target.appendingPathComponent(".DS_Store").path), "(б) поздний .DS_Store тоже в архиве")

        let outcome = try mover.restore(record, deleteArchive: true)
        check((try? String(contentsOf: source.appendingPathComponent("вложенная/.DS_Store"), encoding: .utf8)) == "вид вложенной папки",
              "(в) .DS_Store вернулся вместе с папкой, и это тот самый файл")
        check(fm.fileExists(atPath: source.appendingPathComponent(".DS_Store").path), "(в) .DS_Store корня вернулся")
        check(!outcome.needsAttention, "(в) круг с .DS_Store прошёл без поводов для тревоги: \(outcome.notes)")
        check(outcome.notes == ["Со списком, записанным при переносе, сверено 2 файлов из 2 в архиве."],
              "(в) .DS_Store вычтен с обеих сторон сверки, сверены только настоящие файлы: \(outcome.notes)")

        // Настоящий новый файл — не Finder: такой перенос обязан остановиться.
        let second = rules.home.appendingPathComponent("Downloads/вторая", isDirectory: true)
        try write("данные", to: second.appendingPathComponent("файл.txt"))
        let secondPlan = mover.plan(source: second, volume: volume)
        try write("появился сам", to: second.appendingPathComponent("новый.txt"))
        expectError("(г) настоящий новый файл по-прежнему останавливает перенос",
                    { _ = try mover.execute(secondPlan, deleteOriginal: true, acceptCautions: true) },
                    matching: { if case MoveError.contentMismatch = $0 { return true }; return false })
        check(fm.fileExists(atPath: second.appendingPathComponent("файл.txt").path), "(г) после остановки оригинал на месте")
    }

    section("Возврат: о чём предупреждает сверка со списком сумм") {
        let mount = try hardenMount("harden-notes.sparseimage", fs: "APFS", volumeName: "OFFNOTES")
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard let volume = Volumes.info(for: mount) else { throw CopyError.unreadable(mount.path) }
        let rules = SafetyRules(home: scratch.appendingPathComponent("home-notes", isDirectory: true))
        let mover = SafeMover(rules: rules)

        // Списка сумм рядом с архивом нет: его унесли, потеряли или перенос делали руками.
        // Возврат обязан состояться, но молчать об этом нельзя — интерфейс иначе скажет
        // «каждый файл сверен по SHA-256» там, где сверять было не с чем.
        let orphan = rules.home.appendingPathComponent("Downloads/без-списка", isDirectory: true)
        try write("раз", to: orphan.appendingPathComponent("one.txt"))
        try write("два", to: orphan.appendingPathComponent("two.txt"))
        let orphanRecord = try mover.execute(mover.plan(source: orphan, volume: volume),
                                             deleteOriginal: true, acceptCautions: true)
        let orphanArchive = URL(fileURLWithPath: orphanRecord.archivedPath)
        try fm.removeItem(at: orphanArchive.deletingLastPathComponent()
            .appendingPathComponent(orphanArchive.lastPathComponent + ".sha256"))
        let withoutList = try mover.restore(orphanRecord, deleteArchive: false)
        check(withoutList.record.restored, "без списка сумм возврат состоялся")
        check(withoutList.notes.contains { $0.contains("нет списка контрольных сумм") },
              "о пропавшем списке сумм сказано оговоркой: \(withoutList.notes)")
        check(withoutList.needsAttention, "возврат без списка сумм помечен как то, на что стоит посмотреть")
        check((try? String(contentsOf: orphan.appendingPathComponent("two.txt"), encoding: .utf8)) == "два",
              "данные вернулись и сверены с тем, что лежало в архиве")

        // Из архива пропал файл: человек сам его удалил, пока работал на внешнем диске.
        // Это оговорка, а не отказ, — остальное обязано вернуться.
        let gap = rules.home.appendingPathComponent("Downloads/пропажа", isDirectory: true)
        try write("первый", to: gap.appendingPathComponent("один.txt"))
        try write("второй", to: gap.appendingPathComponent("два.txt"))
        try write("третий", to: gap.appendingPathComponent("три.txt"))
        let gapRecord = try mover.execute(mover.plan(source: gap, volume: volume), deleteOriginal: true, acceptCautions: true)
        try fm.removeItem(at: URL(fileURLWithPath: gapRecord.archivedPath).appendingPathComponent("два.txt"))
        let missing = try mover.restore(gapRecord, deleteArchive: true)
        check(missing.notes.contains { $0.contains("не хватает 1 файлов") && $0.contains("два.txt") },
              "о пропавшем из архива файле сказано оговоркой: \(missing.notes)")
        check(missing.notes.contains { $0.contains("сверено 2 файлов из 2") },
              "сверенное посчитано по тому, что в архиве есть: \(missing.notes)")
        check(missing.needsAttention, "нехватка файла помечена как то, на что стоит посмотреть")
        check(fm.fileExists(atPath: gap.appendingPathComponent("один.txt").path)
              && fm.fileExists(atPath: gap.appendingPathComponent("три.txt").path)
              && !fm.fileExists(atPath: gap.appendingPathComponent("два.txt").path),
              "вернулось всё, что в архиве осталось")
    }

    section("Возврат: имена с кириллицей, пробелами и переводом строки") {
        // Список сумм — текстовый файл формата shasum, а в именах бывает что угодно.
        // Если экранирование и разбор разойдутся, сверка объявит целый архив изменившимся:
        // человек увидит «в архиве появилось столько-то файлов, которых при переносе не было»
        // на совершенно нетронутом архиве.
        let mount = try hardenMount("harden-names.sparseimage", fs: "ExFAT", volumeName: "OFFNAMES")
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard let volume = Volumes.info(for: mount) else { throw CopyError.unreadable(mount.path) }
        let rules = SafetyRules(home: scratch.appendingPathComponent("home-names", isDirectory: true))
        let mover = SafeMover(rules: rules)

        let source = rules.home.appendingPathComponent("Downloads/архив документов", isDirectory: true)
        // «ё» в имени — не украшение: exFAT отдаёт такое имя в другой нормализации Unicode,
        // чем APFS (е + знак над ним вместо одной буквы). Список сумм пишется именами с Mac,
        // а читается именами с внешнего диска, и сверка обязана узнать в них одно и то же.
        let names = ["счёт за январь.txt", "отчет за год.txt", "папка с пробелами/строка\nвторая.txt", "обычный.txt"]
        for name in names { try write("содержимое \(name.count)", to: source.appendingPathComponent(name)) }

        let record = try mover.execute(mover.plan(source: source, volume: volume), deleteOriginal: true, acceptCautions: true)
        let target = URL(fileURLWithPath: record.archivedPath)
        check(record.files == 4, "перенесены все четыре файла (\(record.files))")
        let list = try String(contentsOf: target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + ".sha256"), encoding: .utf8)
        check(list.split(separator: "\n").count == 4,
              "имя с переводом строки не развалило список сумм на лишние строки (\(list.split(separator: "\n").count))")

        let outcome = try mover.restore(record, deleteArchive: true)
        check(outcome.notes == ["Со списком, записанным при переносе, сверено 4 файлов из 4 в архиве."],
              "трудные имена прошли круг без ложных расхождений: \(outcome.notes)")
        check(!outcome.needsAttention, "нетронутый архив с трудными именами не тревожит человека зря")
        for name in names {
            check(fm.fileExists(atPath: source.appendingPathComponent(name).path), "«\(name)» вернулся на место")
        }
    }

    section("Остатки прерванных копирований: чужая машина") {
        // Внешний диск носят между компьютерами. Номер процесса с чужого Mac на этом ничего
        // не значит: он может оказаться и свободным, и занятым посторонней программой.
        // Поэтому чужую свежую метку берегут, а решает возраст метки — её обновляет само
        // копирование, и не тронутая сутками метка ничья, чей бы ни был процесс.
        let mount = try hardenMount("harden-partials.sparseimage", fs: "APFS", volumeName: "OFFPART")
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        let rules = SafetyRules(home: scratch.appendingPathComponent("home-partials", isDirectory: true))
        let mover = SafeMover(rules: rules)

        let archived = mount.appendingPathComponent("Ручной/данные", isDirectory: true)
        try write("данные", to: archived.appendingPathComponent("file.txt"))
        let downloads = rules.home.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let record = try mover.importRecord(archived: archived, original: downloads.appendingPathComponent("данные"),
                                            originalRemoved: true)

        func partial(_ suffix: String, pid: Int32, host: String, at date: Date) throws -> URL {
            let url = downloads.appendingPathComponent(".offload-partial-\(suffix)")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try write("\(pid) \(date.timeIntervalSince1970) \(host)\n", to: url.appendingPathComponent(".offload-lock"))
            // Дату корня ставим последней: по ней остаток выглядит заброшенным, и решать
            // должна метка, а не она.
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5 * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let host = ProcessInfo.processInfo.hostName
        // На другом Mac копирование идёт прямо сейчас — не трогать.
        let foreignFresh = try partial("foreign-fresh", pid: 999_999, host: "другой-mac", at: Date())
        // Метка с того же чужого Mac, но ей трое суток: копирования там давно нет. Номер процесса
        // в ней занят живым процессом (нашим собственным) — верить ему нельзя, решает возраст.
        let foreignStale = try partial("foreign-stale", pid: getpid(), host: "другой-mac", at: Date(timeIntervalSinceNow: -3 * 86_400))
        // Наш же Mac, метка свежая и процесс жив: соседний Offload копирует.
        let liveHere = try partial("live-here", pid: getpid(), host: host, at: Date())

        let outcome = try mover.restore(record, deleteArchive: false)
        check(outcome.record.restored, "возврат прошёл")
        check(fm.fileExists(atPath: foreignFresh.path), "свежая метка другого Mac бережётся: там может идти копирование")
        check(!fm.fileExists(atPath: foreignStale.path), "метка другого Mac, которую сутками не обновляли, остаток не спасает")
        check(fm.fileExists(atPath: liveHere.path), "идущее копирование на этом Mac не тронуто")
        check(fm.fileExists(atPath: downloads.appendingPathComponent("данные/file.txt").path), "данные вернулись на место")
    }
}
