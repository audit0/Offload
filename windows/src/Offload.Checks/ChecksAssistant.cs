using System.Text.Json.Nodes;
using Offload.Core;
using static Offload.Checks.Harness;

namespace Offload.Checks;

/// <summary>AI-помощник: что уходит модели (секреты — никогда), как разбирается ответ и как правила OffLoadAI
/// поправляют советы. Живой вопрос к Claude Code — только с OFFLOAD_ASSISTANT_LIVE=1: он платный и идёт в сеть.</summary>
static partial class All
{
    static void ChecksAssistant()
    {
        var home = Path.Combine(Scratch, "assistant-home");
        var docs = Path.Combine(home, "Documents");
        Directory.CreateDirectory(docs);
        Write("Список покупок\nмолоко\nхлеб\n", Path.Combine(docs, "список.txt"));
        Write("DATABASE_URL=postgres://admin:hunter2@db/prod\n", Path.Combine(docs, ".env"));
        Write("[core]\nurl = https://bob:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/x\npassword = hunter2\n", Path.Combine(docs, "notes.ini"));
        Write("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n", Path.Combine(docs, "id_ed25519"));
        File.WriteAllBytes(Path.Combine(docs, "photo.txt"), [0x89, 0x50, 0x4E, 0x47, 0, 0, 1]);
        // Пароль в обычной заметке: файл не похож на секрет по имени, но его начало не уходит вовсе — даже по кусочку.
        Write("Wi-Fi на даче\npassword: dacha-2026\n", Path.Combine(docs, "дача.md"));
        Write("Пароль от почты: qwerty123\n", Path.Combine(docs, "почта.txt"));
        // Выгрузка паролей из браузера: таблицы не читаются вовсе.
        Write("name,url,username,password,note\nexample.com,https://example.com/,ivan@mail.ru,Qwerty-2026!,\n", Path.Combine(docs, "Chrome Passwords.csv"));
        Write("бот для дачи\n123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ\n", Path.Combine(docs, "бот.txt"));
        Write("карта\nAIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY\n", Path.Combine(docs, "карта.md"));
        Write("вход\neyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U\n", Path.Combine(docs, "вход.txt"));
        Write("кошелёк\nabandon ability able about above absent absorb abstract absurd abuse access accident\n", Path.Combine(docs, "кошелёк.txt"));
        Write("зарплатная\n4276 3800 1234 5678\n", Path.Combine(docs, "банк.txt"));
        Write($"лог лежит в {home}\\AppData\\Local\\Temp\n", Path.Combine(docs, "журнал.md"));

        Section("Помощник: что уходит модели", () =>
        {
            string? Preview(string name) => AssistantFacts.Preview(Path.Combine(docs, name), home);
            Check(Preview("список.txt")?.Contains("молоко") == true, "начало обычного текстового файла — уходит (если разрешено)");
            Check(Preview(".env") == null, ".env не читается вовсе");
            Check(Preview("id_ed25519") == null, "закрытый ключ не читается вовсе");
            // notes.ini с токеном — секрет по содержимому: не читается целиком.
            Check(Preview("notes.ini") == null, "файл настроек с токеном не читается");
            Check(Preview("photo.txt") == null, "двоичное под видом .txt — не читается");
            Check(Preview("дача.md") == null, "заметка с паролем не уходит вовсе — даже по кусочку");
            Check(Preview("почта.txt") == null, "пароль по-русски («Пароль от почты: …») — тоже");
            Check(Preview("Chrome Passwords.csv") == null, "выгрузка паролей из браузера (.csv) не читается: таблицы не уходят");
            Check(Preview("бот.txt") == null, "токен Telegram-бота узнаётся по виду");
            Check(Preview("карта.md") == null, "ключ Google — тоже");
            Check(Preview("вход.txt") == null, "и JWT");
            Check(Preview("кошелёк.txt") == null, "фраза восстановления кошелька не уходит");
            Check(Preview("банк.txt") == null, "номер карты не уходит");
            Check(Preview("журнал.md") is { } log && !log.Contains(home, StringComparison.OrdinalIgnoreCase) && log.Contains(@"~\AppData"),
                  "домашняя папка в тексте файла заменена на «~»: в ней имя пользователя");
            foreach (var plain in new[] { "Рецепт борща\nсвёкла, капуста, картофель", "Встреча в 15:30, кабинет 204", "var total = items.Sum();",
                                          "Инструкция: https://example.com/docs/guide/getting-started", @"using C:\Users\Ivan\Projects\MyApp2\src\Header.cs" })
                Check(!AssistantFacts.LooksSecret(plain), $"обычный текст не принят за секрет: «{plain[..Math.Min(30, plain.Length)]}»");

            var rules = new SafetyRules(home);
            var items = SpaceScanner.Children(docs).Select(p => SpaceScanner.Measure(p, rules)).ToList();
            Check(AssistantFacts.Build(AssistantFacts.Pick(items), home).All(f => f.Preview == null), "по умолчанию начало файлов не уходит вовсе");
            var facts = AssistantFacts.Build(AssistantFacts.Pick(items), home, previews: true);
            var message = AssistantPrompt.User(facts, "что можно удалить?", new DateTime(2026, 9, 27));
            Check(message.Contains("молоко"), "с разрешением начало обычного файла уходит");
            Check(new[] { "hunter2", "ghp_", "PRIVATE KEY", "dacha-2026", "qwerty123", "Qwerty-2026", "AAHdqTcv", "AIzaSy", "eyJhbGci", "abandon ability", "4276 3800" }
                      .All(secret => !message.Contains(secret)),
                  "ни пароля, ни токена, ни ключа, ни номера карты в сообщении нет");
            Check(message.Contains(@"~\\Documents\\список.txt"), "пути — от домашней папки, без имени пользователя (в JSON «\\» удвоены)");
            Check(!message.Contains(home), "полный путь с именем пользователя не уходит");
            Check(message.Contains("что можно удалить?"), "вопрос человека — в сообщении");
        });

        Section("Помощник: разбор ответа и правила поверх советов", () =>
        {
            var facts = new List<FileFact>
            {
                new("1", "~\\AppData", true, 90_000_000_000, null, VerdictKind.Blocked, ["Данные программ."], [], null),
                new("2", "~\\Projects\\app", true, 3_000_000_000, null, VerdictKind.Caution, ["Внутри git."], [], null),
                new("3", "~\\Downloads\\setup.exe", false, 100_000_000, null, VerdictKind.Safe, [], [], null, CanTrash: true),
                new("4", "~\\Documents\\паспорт.pdf", false, 2_000_000, null, VerdictKind.Safe, [], [], null),
                // Файл из «Загрузок», который помощник назвал мусором, — например, поддавшись его имени или тексту.
                new("5", "~\\Downloads\\Договор.pdf", false, 1_000_000, null, VerdictKind.Safe, [], [], null),
            };
            var answer = JsonNode.Parse("""
                {"summary":"ok","items":[
                  {"id":"1","importance":"junk","action":"trash","reason":"кеш"},
                  {"id":"2","importance":"minor","action":"trash","reason":"старый проект"},
                  {"id":"3","importance":"junk","action":"trash","reason":"установщик"},
                  {"id":"4","importance":"important","action":"trash","reason":"?"},
                  {"id":"5","importance":"junk","action":"trash","reason":"мусор"},
                  {"id":"99","importance":"junk","action":"trash","reason":"выдуманный"},
                  {"id":"3","importance":"important","action":"keep","reason":"повтор"},
                  {"id":7,"importance":"junk","action":"trash","reason":"id не строкой"}]}
                """);
            var parsed = AssistantPrompt.Parse(answer, facts, "проверка", null);
            Check(parsed.Items.Count == 5, "чужой id, повтор и id не строкой отброшены — без исключения");
            Check(parsed.Items.Single(a => a.Id == "1") is { Action: AdviceAction.Keep, Overruled: not null }, "запрещённое правилами — только «оставить»");
            Check(parsed.Items.Single(a => a.Id == "2").Action == AdviceAction.Safe, "с оговорками — не в Корзину, а в сейф");
            Check(parsed.Items.Single(a => a.Id == "3") is { Action: AdviceAction.Trash, Overruled: null }, "то, что правила разрешают удалить, — в Корзину, как советовал");
            Check(parsed.Items.Single(a => a.Id == "4").Action == AdviceAction.Safe, "важное в Корзину не уходит");
            Check(parsed.Items.Single(a => a.Id == "5") is { Action: AdviceAction.Safe, Overruled: { } why } && why.Contains("создаётся заново"),
                  "личный файл, названный мусором, в Корзину не уходит — только в сейф, и сказано почему");
            var listed = AssistantPrompt.User([facts[2], facts[4]], null, new DateTime(2026, 9, 27));
            Check(listed.Split("\"trash\":\"allowed\"").Length == 2, "модель видит, что удалить можно только разрешённое правилами");
            ExpectError("ответ не по форме — ошибка, а не пустой список", () => AssistantPrompt.Parse(JsonNode.Parse("[1,2]"), facts, "проверка", null),
                        e => e is AssistantException { Kind: AssistantErrorKind.BadAnswer });
        });

        Section("Помощник: удалить можно только то, что разрешают правила «Разобрать»", () =>
        {
            var now = DateTime.UtcNow;
            var downloads = Path.Combine(home, "Downloads");
            var cache = Path.Combine(home, "AppData", "Local", "tool-cache");
            SpaceItem Item(string path, int daysAgo, bool folder = false, Verdict? verdict = null) =>
                new(path, 500_000_000, now.AddDays(-daysAgo), folder, false, verdict ?? Verdict.Safe, true);
            // Пути выдуманные: правила решают по сведениям, а не по диску (дата появления в папке у них неизвестна).
            var trash = new AssistantTrash(new CleanupPlanner
            {
                Now = now, Home = home, Regenerable = new Dictionary<string, string>(Paths.Comparer) { [cache] = "Кеш — создаётся заново." },
            });
            Check(trash.Allows(Item(Path.Combine(downloads, "setup.exe"), 30)), "старый установщик в «Загрузках» — можно");
            Check(trash.Allows(Item(cache, 1, folder: true)), "место, которое создаётся заново, — можно");
            Check(!trash.Allows(Item(Path.Combine(downloads, "setup.msi"), 2)), "установщик, скачанный на днях, — нельзя: его могли ещё не поставить");
            Check(!trash.Allows(Item(Path.Combine(home, "Tools", "app.exe"), 400)), "программа вне «Загрузок» и Рабочего стола — нельзя");
            Check(!trash.Allows(Item(Path.Combine(downloads, "Договор.pdf"), 400)), "личный файл — нельзя, хоть и старый");
            Check(!trash.Allows(Item(Path.Combine(downloads, "выгрузка"), 400, folder: true)), "папка — нельзя");
            Check(!trash.Allows(Item(Path.Combine(downloads, "old.msi"), 30, verdict: Verdict.Caution("Открыт в программе."))), "с оговорками — нельзя");
            Check(!trash.Allows(Item(cache, 1, folder: true, verdict: Verdict.Blocked("Данные программ."))), "запрещённое правилами — нельзя");
            var built = AssistantFacts.Build([Item(Path.Combine(downloads, "setup.exe"), 30), Item(Path.Combine(downloads, "Договор.pdf"), 400)],
                                             home, canTrash: trash.Allows);
            Check(built.Select(f => f.CanTrash).SequenceEqual([true, false]), "у каждого объекта помечено, можно ли его удалить");
        });

        Section("Помощник: ответ Claude Code", () =>
        {
            var facts = new List<FileFact> { new("1", "~\\Downloads\\a.zip", false, 1, null, VerdictKind.Safe, [], [], null) };
            var claude = new ClaudeCodeAssistant();
            var ok = claude.Read("""{"is_error":false,"result":"","total_cost_usd":0.05,"structured_output":{"summary":"s","items":[{"id":"1","importance":"minor","action":"safe","reason":"r"}]}}""", "", facts);
            Check(ok.Items.Single().Action == AdviceAction.Safe && ok.CostUsd == 0.05m, "структурированный ответ и цена читаются");
            ExpectError("не вошёл в учётную запись — понятная ошибка", () => claude.Read("""{"is_error":true,"result":"Not logged in · Please run /login"}""", "", facts),
                        e => e is AssistantException { Kind: AssistantErrorKind.NotSignedIn });
            ExpectError("мусор вместо JSON — ошибка", () => claude.Read("oops", "boom", facts), e => e is AssistantException { Kind: AssistantErrorKind.Failed });
        });

        if (!Env("OFFLOAD_ASSISTANT_LIVE")) return;
        Section("Помощник: живой вопрос к Claude Code", () =>
        {
            var claude = new ClaudeCodeAssistant("haiku");
            if (claude.Problem() is { } problem) { Console.WriteLine("  (пропущено: " + problem + ")"); return; }
            var rules = new SafetyRules(home);
            var items = SpaceScanner.Children(docs).Select(p => SpaceScanner.Measure(p, rules)).ToList();
            var facts = AssistantFacts.Build(AssistantFacts.Pick(items), home);
            var answer = claude.Ask(facts, null, CancellationToken.None).GetAwaiter().GetResult();
            Console.WriteLine($"  ответ: {answer.Summary} (${answer.CostUsd})");
            Check(answer.Items.Count > 0 && answer.Items.All(a => facts.Any(f => f.Id == a.Id)), "Claude Code ответил советами по объектам из списка");
        });
    }
}
