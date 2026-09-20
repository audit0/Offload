import Darwin
import Foundation
import OffloadCore

/// Проверки на то, ради чего программа написана: данные должны вернуться к человеку.
/// Всё через открытый API SafeMover, как это делает сама программа, и на настоящих
/// дисковых образах — права, служебные файлы и отказы удаления на exFAT и APFS разные.
func checksRestore() {
    guard env["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Возврат данных: пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }

    section("Возврат данных: архивом пользовались") {
        let image = scratch.appendingPathComponent("restore-exfat.sparseimage")
        try Runner.check("hdiutil", ["create", "-size", "2g", "-type", "SPARSE", "-fs", "ExFAT",
                                     "-volname", "OFFBACK", "-quiet", image.path], timeout: 180)
        guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path],
                                                                       timeout: 120).stdout) else {
            throw CopyError.unreadable(image.path)
        }
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard let volume = Volumes.info(for: mount) else { throw CopyError.unreadable(mount.path) }

        let rules = SafetyRules(home: scratch.appendingPathComponent("home-restore", isDirectory: true))
        let mover = SafeMover(rules: rules)
        let source = rules.home.appendingPathComponent("Downloads/models", isDirectory: true)
        try write("веса", to: source.appendingPathComponent("a.bin"))
        try write("ещё веса", to: source.appendingPathComponent("sub/b.bin"))
        try write("#!/bin/sh\necho hi\n", to: source.appendingPathComponent("run.sh"))
        // Человек разложил иконки и выбрал вид окна — это и лежит в .DS_Store.
        try write("вид вложенной папки", to: source.appendingPathComponent("sub/.DS_Store"))

        let plan = mover.plan(source: source, volume: volume)
        // Между планом и переносом человек открыл папку в Finder, и тот записал свой .DS_Store.
        try write("вид корневой папки", to: source.appendingPathComponent(".DS_Store"))
        try write("late", to: source.appendingPathComponent("late.txt"))
        expectError("настоящий новый файл по-прежнему останавливает перенос",
                    { _ = try mover.execute(plan, deleteOriginal: true, acceptCautions: true) },
                    matching: { if case MoveError.contentMismatch = $0 { return true }; return false })
        try fm.removeItem(at: source.appendingPathComponent("late.txt"))

        let record = try mover.execute(plan, deleteOriginal: true, acceptCautions: true)
        let target = URL(fileURLWithPath: record.archivedPath)
        check(!fm.fileExists(atPath: source.path), "появившийся .DS_Store перенос не сорвал, оригинал удалён после сверки")
        check(fm.fileExists(atPath: target.appendingPathComponent("sub/.DS_Store").path),
              ".DS_Store человека уехал в архив, а не пропал вместе с оригиналом")
        check(fm.fileExists(atPath: target.appendingPathComponent(".DS_Store").path), "поздний .DS_Store тоже скопирован")
        check(!fm.fileExists(atPath: target.appendingPathComponent(".offload-lock").path),
              "метка идущего копирования снята и в архив не попала")

        // Дальше архивом пользуются: так и задумано для того, чему можно указать новый путь
        // (папка моделей LM Studio). Файл изменился, рядом появился ещё один.
        try write("новые веса", to: target.appendingPathComponent("a.bin"))
        try write("сам положил", to: target.appendingPathComponent("sub/c.bin"))
        let used = try mover.restore(record, deleteArchive: false)
        check(used.record.restored, "возврат изменённого архива состоялся, а не отказал")
        check(used.notes.contains { $0.contains("изменилось файлов: 1") && $0.contains("a.bin") },
              "об изменившемся файле сказано оговоркой: \(used.notes)")
        check(used.notes.contains { $0.contains("появилось 1 файлов") && $0.contains("sub/c.bin") },
              "о подложенном в архив файле сказано оговоркой: \(used.notes)")
        check(used.notes.contains { $0.contains("сверено 2 файлов из 4") },
              "сказано, сколько файлов сверено со списком переноса и сколько всего в архиве: \(used.notes)")
        check((try? String(contentsOf: source.appendingPathComponent("a.bin"), encoding: .utf8)) == "новые веса",
              "вернулось то, что лежит в архиве сейчас")
        check(fm.fileExists(atPath: source.appendingPathComponent("sub/c.bin").path), "подложенный в архив файл тоже вернулся")
        check(used.needsAttention, "расхождение с архивом помечено как то, на что стоит посмотреть")

        // Второй возврат — уже без списка прав рядом с архивом: так выглядит перенос, сделанный руками.
        try fm.removeItem(at: source)
        try fm.removeItem(at: target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".modes.json"))

        // Остатки прерванных копирований в том же каталоге, куда идёт возврат.
        let downloads = source.deletingLastPathComponent()
        func partial(_ suffix: String) throws -> URL {
            let url = downloads.appendingPathComponent(".offload-partial-\(suffix)")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let host = ProcessInfo.processInfo.hostName
        func lock(_ url: URL, pid: Int32, at date: Date, host: String) throws {
            try write("\(pid) \(date.timeIntervalSince1970) \(host)\n", to: url.appendingPathComponent(".offload-lock"))
            // Дату корня ставим последней: именно она раньше и обманывала проверку.
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5 * 86_400)], ofItemAtPath: url.path)
        }
        // Соседний экземпляр Offload копирует прямо сейчас, а дата корня давно не менялась.
        let live = try partial("live")
        try lock(live, pid: getpid(), at: Date(), host: host)
        // Остаток процесса, которого уже нет.
        let dead = try partial("dead")
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try lock(dead, pid: finished.processIdentifier, at: Date(), host: host)
        // Диск принесли с другого Mac, и там копирование идёт прямо сейчас: номер процесса
        // оттуда на этой машине ничего не значит, даже если он тут свободен.
        let foreign = try partial("foreign")
        try lock(foreign, pid: finished.processIdentifier, at: Date(), host: "другой-mac")
        // Метка, которую сутками не трогали: копирования нет, кем бы ни был тот процесс.
        let forgotten = try partial("forgotten")
        try lock(forgotten, pid: getpid(), at: Date(timeIntervalSinceNow: -3 * 86_400), host: host)
        // Остатки без метки: от версии, которая их не ставила.
        let old = try partial("old")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: old.path)
        let young = try partial("young")

        let strict = try mover.restore(record, deleteArchive: false)
        check(fm.fileExists(atPath: live.path), "чужое идущее копирование не тронуто, хотя по дате выглядит заброшенным")
        check(!fm.fileExists(atPath: dead.path), "остаток процесса, которого нет, убран")
        check(fm.fileExists(atPath: foreign.path), "свежая метка другого Mac бережётся: там может идти копирование")
        check(!fm.fileExists(atPath: forgotten.path), "метка, которую сутками не обновляли, остатка не спасает")
        check(!fm.fileExists(atPath: old.path), "старый остаток без метки убран")
        check(fm.fileExists(atPath: young.path), "свежий остаток без метки не тронут")

        check(strict.notes.contains { $0.contains("папки 700, файлы 600") }, "про выставленные права сказано: \(strict.notes)")
        check(mode(source.appendingPathComponent("run.sh")) == 0o700,
              "скрипт вернулся исполняемым только для владельца (\(mode(source.appendingPathComponent("run.sh")) ?? -1))")
        check(mode(source.appendingPathComponent("a.bin")) == 0o600,
              "обычный файл не стал читаемым всем на машине (\(mode(source.appendingPathComponent("a.bin")) ?? -1))")
        check(mode(source.appendingPathComponent("sub")) == 0o700,
              "каталог не стал доступен всем на машине (\(mode(source.appendingPathComponent("sub")) ?? -1))")
        check(mode(source) == 0o700, "корень возвращённого не стал доступен всем на машине (\(mode(source) ?? -1))")
    }

    section("Возврат данных: архив удалить не удалось") {
        let image = scratch.appendingPathComponent("restore-apfs.sparseimage")
        try Runner.check("hdiutil", ["create", "-size", "2g", "-type", "SPARSE", "-fs", "APFS",
                                     "-volname", "OFFKEEP", "-quiet", image.path], timeout: 180)
        guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path],
                                                                       timeout: 120).stdout) else {
            throw CopyError.unreadable(image.path)
        }
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }

        let rules = SafetyRules(home: scratch.appendingPathComponent("home-keep", isDirectory: true))
        let mover = SafeMover(rules: rules)

        // Обычный случай: архивом не пользовались. Оговорка про сверенное есть всегда,
        // но тревожить ею человека незачем — по needsAttention это и видно.
        let intact = rules.home.appendingPathComponent("Downloads/intact", isDirectory: true)
        try write("раз", to: intact.appendingPathComponent("one.txt"))
        try write("два", to: intact.appendingPathComponent("two.txt"))
        let moved = try mover.execute(mover.plan(source: intact, volume: Volumes.info(for: mount)!),
                                      deleteOriginal: true, acceptCautions: true)
        let clean = try mover.restore(moved, deleteArchive: true)
        check(!clean.needsAttention, "нетронутый архив вернулся без поводов для тревоги: \(clean.notes)")
        check(clean.notes == ["Со списком, записанным при переносе, сверено 2 файлов из 2 в архиве."],
              "сказано, сколько файлов сверено со списком переноса: \(clean.notes)")
        check((try? String(contentsOf: intact.appendingPathComponent("two.txt"), encoding: .utf8)) == "два", "данные вернулись")

        let holder = mount.appendingPathComponent("Archive", isDirectory: true)
        let archived = holder.appendingPathComponent("stuff")
        try write("данные", to: archived.appendingPathComponent("file.txt"))
        let record = try mover.importRecord(archived: archived, original: rules.home.appendingPathComponent("Downloads/stuff"),
                                            originalRemoved: true)
        // Каталог с архивом закрыт на запись: удалить архив не выйдет.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: holder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: holder.path) }

        let outcome = try mover.restore(record, deleteArchive: true)
        check(outcome.record.restored, "возврат засчитан, хотя архив остался на диске")
        check(outcome.needsAttention, "оставшийся архив помечен как то, на что стоит посмотреть")
        check(outcome.notes.contains { $0.contains("архив удалить не удалось") },
              "о неудавшемся удалении архива сказано оговоркой, а не ошибкой: \(outcome.notes)")
        check((try? String(contentsOf: rules.home.appendingPathComponent("Downloads/stuff/file.txt"), encoding: .utf8)) == "данные",
              "данные на Mac и сверены")
        check(fm.fileExists(atPath: archived.path), "архив остался лежать — о нём и сказано в оговорке")
    }
}
