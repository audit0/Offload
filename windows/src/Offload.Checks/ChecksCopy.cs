using System.Text;
using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Копирование со сверкой: обход, копия, побайтовая сверка, подменённые на месте копии ссылки,
// списки контрольных сумм и служебные файлы рядом с архивом на недоверенном диске.
static partial class All
{
    static void ChecksCopy()
    {
        Section("Копирование со сверкой", () =>
        {
            var source = Room("copy-src");
            Write("hello", Path.Combine(source, "a.txt"));
            Write("", Path.Combine(source, "empty"));
            Write("nested", Path.Combine(source, @"dir\sub\n.txt"));
            Write("user file", Path.Combine(source, "._real"));
            Add(Path.Combine(source, "a.txt"), FileAttributes.ReadOnly | FileAttributes.Hidden);
            Junction(Path.Combine(source, @"dir\jump"), Path.Combine(source, @"dir\sub"));
            bool symlinks = CanSymlink;
            if (symlinks) FileLink(Path.Combine(source, @"dir\link"), @"sub\n.txt");

            var entries = TreeWalker.Walk(source, strict: true).entries;
            int expected = symlinks ? 9 : 8;
            Check(entries.Count == expected, $"обход видит все объекты, включая корень, ссылки и файл ._real ({entries.Count})");
            Check(Inspector.Inspect(source).Files == entries.Count(e => e.IsFile), "Inspector и TreeWalker видят одинаковое число файлов");
            Check(entries.Count(e => e.IsLink) == Inspector.Inspect(source).SymlinkCount, "и одинаковое число ссылок");
            Check(!entries.Any(e => e.RelativePath.StartsWith(@"dir\jump\", StringComparison.Ordinal)), "обход не заходит за точку соединения");

            var destination = Path.Combine(Scratch, "copy-dst");
            var hashes = VerifiedCopy.CopyTree(entries, source, destination, keepAttributes: true);
            VerifiedCopy.Verify(entries, hashes, destination);
            Check(Reparse.Read(Path.Combine(destination, @"dir\jump")) is { Type: LinkType.Junction } jump
                  && Paths.Same(jump.Target, Path.Combine(source, @"dir\sub")), "точка соединения скопирована как точка соединения");
            if (symlinks)
                Check(Reparse.Read(Path.Combine(destination, @"dir\link")) is { Type: LinkType.Symbolic, Target: @"sub\n.txt", IsRelative: true },
                      "относительная символическая ссылка скопирована как есть");
            Check(Has(Path.Combine(destination, "a.txt"), FileAttributes.ReadOnly) && Has(Path.Combine(destination, "a.txt"), FileAttributes.Hidden),
                  "атрибуты «только чтение» и «скрытый» сохранены");
            Check(File.GetLastWriteTimeUtc(Path.Combine(destination, @"dir\sub\n.txt")) == File.GetLastWriteTimeUtc(Path.Combine(source, @"dir\sub\n.txt")),
                  "дата изменения сохранена");
            VerifiedCopy.AssertUnchanged(entries, source);

            File.WriteAllText(Path.Combine(destination, @"dir\sub\n.txt"), "NESTED");
            ExpectError("порча копии того же размера обнаруживается сверкой", () => VerifiedCopy.Verify(entries, hashes, destination),
                        ex => IsCopy(ex, CopyErrorKind.VerificationFailed) && ((CopyException)ex).Item == @"dir\sub\n.txt");

            File.SetAttributes(Path.Combine(source, "a.txt"), FileAttributes.Normal);
            File.WriteAllText(Path.Combine(source, "a.txt"), "changed!");
            ExpectError("изменение источника во время переноса обнаруживается", () => VerifiedCopy.AssertUnchanged(entries, source),
                        ex => IsCopy(ex, CopyErrorKind.ChangedDuringCopy) && ((CopyException)ex).Item == "a.txt");

            // Подменённый на месте копии объект: файл назначения создаётся только новым.
            var victim = Path.Combine(Scratch, "victim.txt");
            Write("do not touch", victim);
            if (symlinks)
            {
                var trap = Path.Combine(Scratch, "trap");
                FileLink(trap, victim);
                ExpectError("подложенная ссылка на месте копии не срабатывает",
                            () => VerifiedCopy.CopyFile(Path.Combine(source, "a.txt"), trap), ex => IsCopy(ex, CopyErrorKind.DestinationExists));
                Check(Read(victim) == "do not touch", "файл, на который указывала ссылка, не изменился");
                // Источник подменили ссылкой после обхода: чтение по ней не уходит.
                var swapped = Path.Combine(Scratch, "swapped.txt");
                FileLink(swapped, victim);
                ExpectError("источник-ссылка не читается как файл", () => VerifiedCopy.CopyFile(swapped, Path.Combine(Scratch, "swapped-copy.txt")),
                            ex => IsCopy(ex, CopyErrorKind.Unreadable));
                Check(!Exists(Path.Combine(Scratch, "swapped-copy.txt")), "копии по подменённому источнику не появилось");
            }
            var trapDir = Path.Combine(Scratch, "trap-dir");
            var victimDir = Room("victim-dir");
            Junction(trapDir, victimDir);
            ExpectError("подложенная точка соединения на месте папки копии не срабатывает",
                        () => VerifiedCopy.CopyTree(entries.Take(1).ToList(), source, trapDir, keepAttributes: false),
                        ex => IsCopy(ex, CopyErrorKind.DestinationExists));
            Check(Directory.GetFileSystemEntries(victimDir).Length == 0, "в папку за точкой соединения ничего не записано");

            // Служебные «._»-двойники Mac: только настоящий двойник с подписью AppleDouble рядом со своим файлом.
            var sidecar = Path.Combine(Scratch, "appledouble");
            Write("jpeg", Path.Combine(sidecar, "photo.jpg"));
            File.WriteAllBytes(Path.Combine(sidecar, "._photo.jpg"), [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]);
            Write("данные человека", Path.Combine(sidecar, "._notes.txt"));
            Write("notes", Path.Combine(sidecar, "notes.txt"));
            File.WriteAllBytes(Path.Combine(sidecar, "._alone.jpg"), [0x00, 0x05, 0x16, 0x07]);
            var sideEntries = TreeWalker.Walk(sidecar, strict: true).entries;
            TreeEntry E(string name) => sideEntries.First(e => e.RelativePath == name);
            Check(SafeMover.IsGeneratedAppleDouble(E("._photo.jpg"), sidecar, null), "двойник с подписью AppleDouble рядом с файлом узнаётся");
            Check(!SafeMover.IsGeneratedAppleDouble(E("._notes.txt"), sidecar, null), "файл человека с именем на «._» без подписи — не двойник");
            Check(!SafeMover.IsGeneratedAppleDouble(E("._alone.jpg"), sidecar, null), "без файла рядом — не двойник");
            Check(!SafeMover.IsGeneratedAppleDouble(E("._photo.jpg"), sidecar, new Dictionary<string, string> { ["._photo.jpg"] = "x" }),
                  "записанный в список сумм при переносе — файл человека, а не двойник");
        });

        Section("Списки контрольных сумм", () =>
        {
            var list = VerifiedCopy.ChecksumList(new Dictionary<string, string> { [""] = "ab", ["x\ny"] = "cd" }, "item");
            Check(list.Contains("ab  item\n") && list.Contains("\\cd  item/x\\ny"), "имена с переводом строки экранируются, как у sha256sum");
            var sample = new Dictionary<string, string>
            {
                [""] = new string('a', 64), [@"dir\f.txt"] = new string('b', 64), ["x\ny"] = new string('c', 64), [@"пробел и ё\a b.txt"] = new string('d', 64),
            };
            var parsed = VerifiedCopy.ParseChecksumList(VerifiedCopy.ChecksumList(sample, "item"), "item");
            Check(parsed != null && parsed.Count == sample.Count && sample.All(p => parsed.TryGetValue(p.Key, out var v) && v == p.Value),
                  "список контрольных сумм читается обратно, включая имя с переводом строки");
            Check(VerifiedCopy.ChecksumList(sample, "item").Contains("item/dir/f.txt"), "пути в списке — через «/», как у sha256sum на Mac");
            var fromMac = VerifiedCopy.ParseChecksumList(new string('e', 64) + "  item/Папка/файл.txt\n", "item");
            Check(fromMac != null && fromMac.ContainsKey(@"Папка\файл.txt"), "список, записанный на Mac, читается и на Windows");
            Check(VerifiedCopy.ParseChecksumList("мусор\n", "item") == null, "чужой файл вместо списка сумм не разбирается");
            Check(VerifiedCopy.ParseChecksumList(new string('a', 64) + "  other/x.txt\n", "item") == null,
                  "строка про чужой архив не принимается: список подложили от другого переноса");
            Check(VerifiedCopy.ParseChecksumList(new string('z', 64) + "  item\n", "item") == null, "не шестнадцатеричная сумма — не список");
            var crlf = VerifiedCopy.ParseChecksumList(new string('a', 64) + "  item/a.txt\r\n", "item");
            Check(crlf != null && crlf.ContainsKey("a.txt"), "список с переводами строк Windows тоже читается");
        });

        Section("Служебные файлы рядом с архивом: ссылки, папки и огромные файлы", () =>
        {
            var room = Room("sidecars");
            var victim = Path.Combine(room, "victim.txt");
            Write("секрет с этого компьютера", victim);
            Write("обычный", Path.Combine(room, "plain.txt"));
            Check(SafeFile.Read(Path.Combine(room, "plain.txt"), 1024) is { } data && Encoding.UTF8.GetString(data) == "обычный", "обычный файл читается");
            Check(SafeFile.Read(Path.Combine(room, "plain.txt"), 4) == null, "файл больше предела не читается");
            Directory.CreateDirectory(Path.Combine(room, "folder.sha256"));
            Check(SafeFile.Read(Path.Combine(room, "folder.sha256"), 1024) == null, "папка на месте служебного файла не читается");
            Check(SafeFile.Read(Path.Combine(room, "нет такого"), 1024) == null, "нет файла — null, без исключения");
            if (CanSymlink)
            {
                FileLink(Path.Combine(room, "link.sha256"), victim);
                Check(SafeFile.Read(Path.Combine(room, "link.sha256"), 1 << 20) == null, "ссылка на месте служебного файла не читается");
                ExpectError("новый служебный файл не пишется поверх подложенной ссылки",
                            () => SafeFile.CreateExclusive(Path.Combine(room, "link.sha256"), Encoding.UTF8.GetBytes("затёрто")),
                            ex => IsCopy(ex, CopyErrorKind.DestinationExists));
                Check(Read(victim) == "секрет с этого компьютера", "файл за ссылкой не изменился");
            }
            Junction(Path.Combine(room, "junction.attrs.json"), room);
            Check(SafeFile.Read(Path.Combine(room, "junction.attrs.json"), 1 << 20) == null, "точка соединения на месте служебного файла не читается");
            ExpectError("существующий файл не перезаписывается", () => SafeFile.CreateExclusive(Path.Combine(room, "plain.txt"), [1]),
                        ex => IsCopy(ex, CopyErrorKind.DestinationExists));
            Check(Read(Path.Combine(room, "plain.txt")) == "обычный", "содержимое существующего файла не тронуто");

            // Огромный список сумм на недоверенном диске не должен съесть память.
            var huge = Path.Combine(room, "huge.sha256");
            using (var stream = new FileStream(huge, FileMode.CreateNew)) stream.SetLength(SafeMover.MaxSidecarBytes + 1L);
            Check(SafeFile.Read(huge, SafeMover.MaxSidecarBytes) == null, "огромный служебный файл не читается целиком");
            var archive = Path.Combine(room, "huge");
            Directory.CreateDirectory(archive);
            Check(SafeMover.StoredChecksums(archive).Kind == SafeMover.StoredChecksumKind.Unreadable, "огромный список сумм — «не читается», а не падение");
            Check(!SafeMover.ApplyModes(huge, room, new HashSet<string> { "" }), "огромный список атрибутов не применяется");
        });

        Section("Проводник не срывает перенос", () =>
        {
            var source = Room("ds-src");
            Write("data", Path.Combine(source, @"sub\file.txt"));
            var entries = TreeWalker.Walk(source, strict: true).entries;
            // Проводник пишет desktop.ini и Thumbs.db, когда человек просто открывает папку и меняет её вид.
            Write("[.ShellClassInfo]", Path.Combine(source, @"sub\desktop.ini"));
            Write("", Path.Combine(source, "Thumbs.db"));
            Write("", Path.Combine(source, @"sub\.DS_Store"));
            Check(() =>
            {
                VerifiedCopy.AssertUnchanged(entries, source);
                return true;
            }, "появление desktop.ini, Thumbs.db и .DS_Store не считается изменением источника");
            Write("new", Path.Combine(source, @"sub\other.txt"));
            ExpectError("настоящий новый файл в папке по-прежнему останавливает перенос", () => VerifiedCopy.AssertUnchanged(entries, source),
                        ex => IsCopy(ex, CopyErrorKind.ChangedDuringCopy));
        });
    }
}
