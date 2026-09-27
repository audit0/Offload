using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>AI-помощник по файлам: смотрит на содержимое папки и говорит, что важно, что менее важно, а что мусор.
/// Сам ничего не делает — каждый совет выполняет человек, теми же путями, что и без помощника.</summary>
public sealed class AssistantModel : Observable
{
    public enum StageKind { Idle, Scanning, Thinking, Done, Failed }

    const string ConsentKey = "assistant.consent";
    const string KindKey = "assistant.provider";
    const string ApiKeyKey = "assistant.apiKey";
    const string LocalModelKey = "assistant.ollamaModel";
    const string ServerKey = "assistant.server";

    /// <summary>Где думает помощник — по порядку: Claude Code на компьютере, ключ API, локальная модель, сервер OffLoadAI.</summary>
    public enum Kind { ClaudeCode, ApiKey, Local, Server }

    public static string Title(Kind kind) => kind switch
    {
        Kind.ClaudeCode => "Claude Code",
        Kind.ApiKey => "Ключ API",
        Kind.Local => "На компьютере",
        _ => "Сервер OffLoadAI",
    };

    readonly Dictionary<Kind, IAssistantProvider> providers;

    public AssistantModel(Func<string?> license)
    {
        providers = new()
        {
            [Kind.ClaudeCode] = new ClaudeCodeAssistant(),
            [Kind.ApiKey] = new ApiKeyAssistant(() => ApiKeyAssistant.Unprotect(Settings.Get<string>(ApiKeyKey))),
            [Kind.Local] = new OllamaAssistant(() => Settings.Get<string>(LocalModelKey)),
            [Kind.Server] = new BotAssistant(license, () => Settings.Get<string>(ServerKey), "offloadai-windows/" + Dialogs.Version),
        };
        provider = Enum.TryParse<Kind>(Settings.Get<string>(KindKey), out var saved) ? saved : Kind.ClaudeCode;
    }

    Kind provider;
    public Kind ProviderKind
    {
        get => provider;
        set
        {
            if (!Set(ref provider, value)) return;
            Settings.Set(KindKey, value.ToString());
            Error = null;
            Raise(nameof(Provider));
        }
    }
    public IAssistantProvider Provider => providers[provider];
    public OllamaAssistant Local => (OllamaAssistant)providers[Kind.Local];

    public bool HasApiKey => !string.IsNullOrEmpty(Settings.Get<string>(ApiKeyKey));
    public void SaveApiKey(string? key)
    {
        Settings.Set(ApiKeyKey, string.IsNullOrWhiteSpace(key) ? null : ApiKeyAssistant.Protect(key));
        Error = null;
        Raise(nameof(HasApiKey), nameof(Provider));
    }

    public string? LocalModel
    {
        get => Settings.Get<string>(LocalModelKey);
        set { Settings.Set(LocalModelKey, value); Raise(); }
    }

    StageKind stage;
    public StageKind Stage { get => stage; private set { if (Set(ref stage, value)) Raise(nameof(IsBusy)); } }
    public bool IsBusy => Stage is StageKind.Scanning or StageKind.Thinking;

    string? status;
    public string? Status { get => status; private set => Set(ref status, value); }
    string? error;
    public string? Error { get => error; private set => Set(ref error, value); }
    AssistantAnswer? answer;
    public AssistantAnswer? Answer { get => answer; private set => Set(ref answer, value); }
    string? folder;
    /// <summary>Папка, которую разбирали последней.</summary>
    public string? Folder { get => folder; private set => Set(ref folder, value); }

    /// <summary>Человек согласился, что сведения о файлах уходят модели. Без этого помощник не запускается.</summary>
    public bool Consent
    {
        get => Demo.IsOn || Settings.Get<bool?>(ConsentKey) == true;
        set { Settings.Set(ConsentKey, value); Raise(); }
    }

    /// <summary>Объект по номеру из ответа — настоящий путь, а не тот, что видел помощник.</summary>
    Dictionary<string, SpaceItem> items = [];
    public SpaceItem? Item(string id) => items.GetValueOrDefault(id);

    /// <summary>Что уже сделано по совету: «в Корзине», «в сейфе», «оставлено».</summary>
    Dictionary<string, string> done = [];
    public string? Done(string id) => done.GetValueOrDefault(id);
    public void MarkDone(string id, string outcome)
    {
        done = new Dictionary<string, string>(done) { [id] = outcome };
        Raise(nameof(Answer));
    }

    CancellationTokenSource? cancel;

    public async void Run(string target, string? question, AppModel app)
    {
        if (IsBusy || !Consent) return;
        cancel = new CancellationTokenSource();
        var token = cancel.Token;
        Folder = target;
        Error = null;
        Answer = null;
        done = [];
        Stage = StageKind.Scanning;
        Status = "Считаю, что лежит в папке…";
        try
        {
            List<SpaceItem> measured;
            if (Demo.IsOn) measured = DemoDownloads(app.Rules.Home);
            else
            {
                var found = new List<SpaceItem>();
                var children = SpaceScanner.Children(target);
                await SpaceScanner.Scan(children, app.Rules, () => token.IsCancellationRequested, item =>
                {
                    lock (found) found.Add(item);
                    Ui.Post(() => Status = $"Считаю, что лежит в папке… {found.Count} из {children.Count}");
                });
                measured = found;
            }
            token.ThrowIfCancellationRequested();
            if (measured.Count == 0)
            {
                Fail("Папка пуста — разбирать нечего.");
                return;
            }
            var picked = AssistantFacts.Pick(measured);
            items = picked.Select((item, i) => (item, i)).ToDictionary(p => (p.i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), p => p.item);
            var home = app.Rules.Home;
            var facts = await Task.Run(() => AssistantFacts.Build(picked, home), token);
            Stage = StageKind.Thinking;
            Status = $"Помощник смотрит {facts.Count} {Plural.Ru(facts.Count, "объект", "объекта", "объектов")}…";
            Answer = Demo.IsOn ? DemoAnswer(facts) : await Provider.Ask(facts, question, token);
            Stage = StageKind.Done;
            Status = null;
        }
        catch (OperationCanceledException)
        {
            Stage = StageKind.Idle;
            Status = null;
        }
        catch (AssistantException problem) { Fail(problem.Message); }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException or RunnerException)
        {
            Fail(problem.Message);
        }
    }

    void Fail(string message)
    {
        Error = message;
        Status = null;
        Stage = StageKind.Failed;
    }

    public void Cancel() => cancel?.Cancel();

    /// <summary>В Корзину — вернуть можно, пока Корзина не очищена. Правила Offload проверяются ещё раз:
    /// помощник мог ошибиться, а объект — измениться с тех пор.</summary>
    public async Task<string?> Trash(string id, AppModel app)
    {
        if (Item(id) is not { } item) return "Объект не найден.";
        if (Demo.IsOn)
        {
            MarkDone(id, "в Корзине");
            return null;
        }
        var verdict = app.Rules.PathVerdict(item.Path);
        if (verdict.Kind != VerdictKind.Safe) return "Правила OffLoadAI не дают отправить это в Корзину: " + string.Join(" ", verdict.Notes);
        try
        {
            await Task.Run(() => RecycleBin.Trash(item.Path));
            MarkDone(id, "в Корзине");
            app.Space.InvalidateAll();
            return null;
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return problem.Message;
        }
    }

    /// <summary>Вымышленные «Загрузки» для снимков и демонстрации: что там обычно лежит.</summary>
    static List<SpaceItem> DemoDownloads(string home)
    {
        var folder = Path.Combine(home, "Downloads");
        SpaceItem Item(string name, double gigabytes, int daysAgo, bool isFolder = false) =>
            new(Path.Combine(folder, name), (long)(gigabytes * 1_000_000_000), DateTime.Now.AddDays(-daysAgo), isFolder, false, Verdict.Safe, true);
        return
        [
            Item("Отпуск 2023 (1).mp4", 4.1, 380), Item("Фото с дачи.zip", 2.3, 410), Item("Win11_24H2_Russian_x64.iso", 5.8, 290),
            Item("temp-export", 0.8, 200, isFolder: true), Item("node-v22.11.0-x64.msi", 0.03, 320), Item("ChromeSetup.exe", 0.0014, 500),
            Item("Договор аренды 2026.pdf", 0.002, 40), Item("Выписка ЕГРН.pdf", 0.001, 95),
        ];
    }

    /// <summary>Ответ для снимков и демонстрации: без сети, по вымышленным «Загрузкам».</summary>
    static AssistantAnswer DemoAnswer(IReadOnlyList<FileFact> facts)
    {
        var advice = facts.Select(fact => Paths.Name(fact.Path) switch
        {
            "Отпуск 2023 (1).mp4" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Видео из отпуска с «(1)» в имени — похоже на повторную загрузку; сохранить стоит, но не на диске компьютера."),
            "Фото с дачи.zip" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Архив с личными фото: нужен, но редко — место ему в сейфе."),
            "Win11_24H2_Russian_x64.iso" => new Advice(fact.Id, Importance.Junk, AdviceAction.Trash, "Образ установки Windows: скачивается заново с сайта Microsoft."),
            "temp-export" => new Advice(fact.Id, Importance.Junk, AdviceAction.Trash, "Временная выгрузка, которую давно не открывали."),
            "node-v22.11.0-x64.msi" or "ChromeSetup.exe" => new Advice(fact.Id, Importance.Junk, AdviceAction.Trash, "Установщик уже поставленной программы."),
            _ => new Advice(fact.Id, Importance.Important, AdviceAction.Keep, "Личный документ — оставить на месте."),
        }).ToList();
        return new AssistantAnswer("В «Загрузках» почти 7 ГБ мусора — образ Windows, установщики и старая выгрузка. Видео и архив с фото лучше убрать в сейф, документы оставить.",
                                   advice, "Демонстрация");
    }
}
