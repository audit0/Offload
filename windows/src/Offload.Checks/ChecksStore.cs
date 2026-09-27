using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// База решений на системной SQLite (winsqlite3): решения, «не предлагать», итоги, отпечатки и обновление старых схем.
static partial class All
{
    static DateTime At(double seconds) => DateTime.UnixEpoch.AddSeconds(seconds);

    static void ChecksStore()
    {
        Section("Разбор: база решений", () =>
        {
            var path = Path.Combine(Scratch, @"decisions\decisions.sqlite");
            using (var store = new DecisionStore(path))
            {
                store.Record([new(@"C:\a", CleanupAction.Keep, 10, DecidedAt: At(100)), new(@"C:\b", CleanupAction.Safe, 20, DecidedAt: At(100))]);
                store.Record([new(@"C:\a", CleanupAction.Backup, 10, DecidedAt: At(200))]);
                store.RecordRun(new DecisionStore.Run(At(200), 5, 20, 1, 0));
                var decisions = store.LastDecisions();
                Check(decisions.Count == 2 && decisions[@"C:\a"] == CleanupAction.Backup && decisions[@"C:\b"] == CleanupAction.Safe,
                      "по каждому пути помнится последнее решение");
                var counts = store.Counts(@"C:\a");
                Check(counts.Count == 2 && counts[CleanupAction.Keep] == 1 && counts[CleanupAction.Backup] == 1, "считается, сколько раз что выбирали");
                Check(store.LastDecisions().ContainsKey(@"c:\A"), "пути в ответе сравниваются без учёта регистра, как в Windows");
            }
            using var reopened = new DecisionStore(path);
            Check(reopened.LastDecisions()[@"C:\a"] == CleanupAction.Backup, "решения переживают перезапуск программы");
            Check(reopened.LastRun()?.MovedBytes == 20, "итог последнего разбора сохранён");

            const string tricky = @"C:\Users\q\Мои «папки»\it's; DROP TABLE decisions;--";
            reopened.Record([new(tricky, CleanupAction.Keep, 1)]);
            Check(reopened.LastDecisions()[tricky] == CleanupAction.Keep, "кавычки и точки с запятой в пути — просто текст, не команды");

            var broken = Path.Combine(Scratch, @"decisions\broken.sqlite");
            File.WriteAllText(broken, "это не база, а просто текст, который случайно так назвали");
            ExpectError("испорченный файл базы — понятная ошибка, а не падение", () => new DecisionStore(broken).Dispose(),
                        ex => ex is DecisionStore.StoreException);

            using var longStore = new DecisionStore(null);
            for (int index = 0; index < DecisionStore.DecisionsPerPath + 5; index++)
                longStore.Record([new(@"C:\often", index % 2 == 0 ? CleanupAction.Keep : CleanupAction.Safe, 1, DecidedAt: At(1000 + index))]);
            Check(longStore.Counts(@"C:\often").Values.Sum() == DecisionStore.DecisionsPerPath, "по одному пути хранятся только последние решения — база не растёт без конца");
            Check(longStore.LastDecisions()[@"C:\often"] == CleanupAction.Keep, "последнее решение при этом не теряется");

            using var memory = new DecisionStore(null);
            memory.Record([new(@"C:\x", CleanupAction.Trash, 1)]);
            Check(memory.LastDecisions() is { Count: 1 } only && only[@"C:\x"] == CleanupAction.Trash, "база в памяти работает и ничего не пишет на диск");
            Check(memory.LastRun() == null, "разборов ещё не было — итога нет");

            reopened.Ignore(@"C:\Users\q\Videos", At(10));
            reopened.Ignore(@"C:\Users\q\VM «Ubuntu»; DROP", At(20));
            reopened.Ignore(@"C:\Users\q\Videos", At(30));
            using (var again = new DecisionStore(path))
                Check(again.IgnoredPaths().SequenceEqual([@"C:\Users\q\Videos", @"C:\Users\q\VM «Ubuntu»; DROP"]),
                      "«не предлагать» переживает перезапуск, повтор не дублирует, сначала недавнее");
            reopened.Unignore(@"C:\Users\q\Videos");
            Check(reopened.IgnoredPaths().SequenceEqual([@"C:\Users\q\VM «Ubuntu»; DROP"]), "вернуть в разбор можно");
            reopened.ForgetDecisions();
            Check(reopened.IgnoredPaths().Count == 1 && reopened.LastDecisions().Count == 0, "«Забыть мои решения» не трогает то, что вы просили не предлагать");
        });

        Section("Дубликаты: отпечатки в базе", () =>
        {
            var path = Path.Combine(Scratch, @"decisions-v1\decisions.sqlite");
            Directory.CreateDirectory(Paths.Parent(path));
            // База первой версии, как её оставил прошлый OffLoadAI (на Mac или здесь).
            Check(RawSql.Exec(path, """
                CREATE TABLE decisions (id INTEGER PRIMARY KEY, path TEXT NOT NULL, action TEXT NOT NULL, bytes INTEGER NOT NULL, decided_at REAL NOT NULL);
                CREATE INDEX decisions_path ON decisions(path, decided_at);
                CREATE TABLE runs (id INTEGER PRIMARY KEY, started_at REAL NOT NULL, trashed_bytes INTEGER NOT NULL, moved_bytes INTEGER NOT NULL, added_to_backup INTEGER NOT NULL, failures INTEGER NOT NULL);
                INSERT INTO decisions (path, action, bytes, decided_at) VALUES ('C:\old', 'keep', 1, 1);
                INSERT INTO decisions (path, action, bytes, decided_at) VALUES ('C:\future', 'compress', 1, 1);
                PRAGMA user_version = 1;
                """), "в старой базе есть решение");

            using (var store = new DecisionStore(path))
            {
                var decisions = store.LastDecisions();
                Check(decisions.Count == 1 && decisions[@"C:\old"] == CleanupAction.Keep, "после обновления прежние решения на месте, неизвестные действия пропущены");
                var prints = new[] { new Fingerprint(@"C:\a", 10, 1.5, 7, "e", "f"), new Fingerprint(@"C:\b", 20, 2.5, 8, "e2", null) };
                store.SaveFingerprints(prints, At(100));
                var saved = store.Fingerprints();
                Check(saved.Count == 2 && saved[@"C:\a"] == prints[0] && saved[@"C:\b"] == prints[1], "отпечатки сохраняются, в том числе без полного хеша");
                store.SaveFingerprints([new Fingerprint(@"C:\a", 11, 3, 7, "e3", "f3")], At(200));
                Check(store.Fingerprints()[@"C:\a"].Size == 11, "новый отпечаток того же файла заменяет старый");
                store.ForgetFingerprints(At(150));
                Check(store.Fingerprints().Keys.SequenceEqual([@"C:\a"]), "отпечатки, которых последний поиск не касался, забываются");
            }
            using (var reopened = new DecisionStore(path))
                Check(reopened.Fingerprints()[@"C:\a"].Full == "f3", "отпечатки переживают перезапуск");
            Check(RawSql.Scalar(path, "PRAGMA user_version") == 4, "версия схемы — последняя, 4");
        });

        Section("Привычки: база", () =>
        {
            var path = Path.Combine(Scratch, @"decisions-v2\decisions.sqlite");
            Directory.CreateDirectory(Paths.Parent(path));
            // База второй версии: решения без вида и даты, отпечатки уже есть. Пути — как их записал Mac.
            Check(RawSql.Exec(path, """
                CREATE TABLE decisions (id INTEGER PRIMARY KEY, path TEXT NOT NULL, action TEXT NOT NULL, bytes INTEGER NOT NULL, decided_at REAL NOT NULL);
                CREATE INDEX decisions_path ON decisions(path, decided_at);
                CREATE TABLE runs (id INTEGER PRIMARY KEY, started_at REAL NOT NULL, trashed_bytes INTEGER NOT NULL, moved_bytes INTEGER NOT NULL, added_to_backup INTEGER NOT NULL, failures INTEGER NOT NULL);
                CREATE TABLE fingerprints (path TEXT PRIMARY KEY, size INTEGER NOT NULL, modified REAL NOT NULL, inode INTEGER NOT NULL, edges TEXT, full TEXT, seen_at REAL NOT NULL);
                INSERT INTO decisions (path, action, bytes, decided_at) VALUES ('C:\Users\q\Videos\old', 'keep', 7, 10);
                INSERT INTO fingerprints VALUES ('C:\f', 1, 1, 1, 'e', 'f', 1);
                PRAGMA user_version = 2;
                """), "в старой базе есть решение и отпечаток");

            using var store = new DecisionStore(path);
            var before = store.History();
            Check(before.Count == 1 && before[0].Kind == null && before[0].Modified == null && before[0].Suggested == null && before[0].DecidedAt == At(10),
                  "после обновления старое решение на месте, чего оно не знало — пусто");
            store.Record([
                new(@"C:\Users\q\Videos\a", CleanupAction.Keep, 5, CleanupAction.Safe, DecisionKind.Folder, At(1_000), At(2_000)),
                new(@"C:\Users\q\Videos\a", CleanupAction.Safe, 6, CleanupAction.Safe, DecisionKind.Folder, At(1_500), At(3_000)),
            ]);
            var history = store.History();
            var latest = history.FirstOrDefault(d => d.Path == @"C:\Users\q\Videos\a");
            Check(history.Count == 2 && latest?.Action == CleanupAction.Safe && latest.Bytes == 6, "по каждому пути — одно, последнее решение");
            Check(latest?.Suggested == CleanupAction.Safe && latest.Kind == DecisionKind.Folder && latest.Modified == At(1_500), "вид, дата изменения и предложенное сохраняются");
            Check(store.LastDecisions()[@"C:\Users\q\Videos\a"] == CleanupAction.Safe, "«как в прошлый раз» видит новые записи");

            store.RecordRun(new DecisionStore.Run(DateTime.UtcNow, 1, 2, 0, 0));
            store.ForgetDecisions();
            Check(store.History().Count == 0 && store.LastDecisions().Count == 0, "решения забыты целиком");
            Check(store.LastRun() != null && store.Fingerprints().ContainsKey(@"C:\f"), "итоги разборов и отпечатки файлов остаются");
            Check(RawSql.Scalar(path, "PRAGMA user_version") == 4, "версия схемы — последняя, 4");
        });
    }
}
