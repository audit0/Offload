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

        Section("Помощник: что уходит модели", () =>
        {
            Check(AssistantFacts.Preview(Path.Combine(docs, "список.txt"), home)?.Contains("молоко") == true, "начало обычного текстового файла — уходит");
            Check(AssistantFacts.Preview(Path.Combine(docs, ".env"), home) == null, ".env не читается вовсе");
            Check(AssistantFacts.Preview(Path.Combine(docs, "id_ed25519"), home) == null, "закрытый ключ не читается вовсе");
            // notes.ini с токеном — секрет по содержимому: не читается целиком.
            Check(AssistantFacts.Preview(Path.Combine(docs, "notes.ini"), home) == null, "файл настроек с токеном не читается");
            Check(AssistantFacts.Preview(Path.Combine(docs, "photo.txt"), home) == null, "двоичное под видом .txt — не читается");

            var rules = new SafetyRules(home);
            var items = SpaceScanner.Children(docs).Select(p => SpaceScanner.Measure(p, rules)).ToList();
            var facts = AssistantFacts.Build(AssistantFacts.Pick(items), home);
            var message = AssistantPrompt.User(facts, "что можно удалить?", new DateTime(2026, 9, 27));
            Check(!message.Contains("hunter2") && !message.Contains("ghp_") && !message.Contains("PRIVATE KEY"), "ни пароля, ни токена, ни ключа в сообщении нет");
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
                new("3", "~\\Downloads\\setup.exe", false, 100_000_000, null, VerdictKind.Safe, [], [], null),
                new("4", "~\\Documents\\паспорт.pdf", false, 2_000_000, null, VerdictKind.Safe, [], [], null),
            };
            var answer = JsonNode.Parse("""
                {"summary":"ok","items":[
                  {"id":"1","importance":"junk","action":"trash","reason":"кеш"},
                  {"id":"2","importance":"minor","action":"trash","reason":"старый проект"},
                  {"id":"3","importance":"junk","action":"trash","reason":"установщик"},
                  {"id":"4","importance":"important","action":"trash","reason":"?"},
                  {"id":"99","importance":"junk","action":"trash","reason":"выдуманный"},
                  {"id":"3","importance":"important","action":"keep","reason":"повтор"}]}
                """);
            var parsed = AssistantPrompt.Parse(answer, facts, "проверка", null);
            Check(parsed.Items.Count == 4, "чужой id и повтор отброшены");
            Check(parsed.Items.Single(a => a.Id == "1") is { Action: AdviceAction.Keep, Overruled: not null }, "запрещённое правилами — только «оставить»");
            Check(parsed.Items.Single(a => a.Id == "2").Action == AdviceAction.Safe, "с оговорками — не в Корзину, а в сейф");
            Check(parsed.Items.Single(a => a.Id == "3") is { Action: AdviceAction.Trash, Overruled: null }, "безопасный мусор — в Корзину, как советовал");
            Check(parsed.Items.Single(a => a.Id == "4").Action == AdviceAction.Safe, "важное в Корзину не уходит");
            ExpectError("ответ не по форме — ошибка, а не пустой список", () => AssistantPrompt.Parse(JsonNode.Parse("[1,2]"), facts, "проверка", null),
                        e => e is AssistantException { Kind: AssistantErrorKind.BadAnswer });
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
