using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>AI-помощник по файлам: смотрит на содержимое папки и говорит, что важно, что менее важно, а что мусор.
/// Сам ничего не делает — каждый совет выполняет человек, теми же путями, что и без помощника.</summary>
public sealed class AssistantModel : Observable
{
    public enum StageKind { Idle, Scanning, Thinking, Done, Failed }

    /// <summary>Согласие — отдельно для каждого варианта: сведения уходят в разные места. Ключи новые: прежнее общее
    /// согласие давалось на описание, по которому начало текстовых файлов уходило всегда.</summary>
    static string ConsentKey(Kind kind) => "assistant.consent." + kind;
    const string KindKey = "assistant.provider";
    const string ApiKeyKey = "assistant.apiKey";
    const string LocalModelKey = "assistant.ollamaModel";
    const string ServerKey = "assistant.server";
    const string PreviewsKey = "assistant.previews";

    /// <summary>Где думает помощник — по порядку: Claude Code на компьютере, ключ API, локальная модель, сервер OffLoadAI.</summary>
    public enum Kind { ClaudeCode, ApiKey, Local, Server }

    public static string Title(Kind kind) => kind switch
    {
        Kind.ClaudeCode => "Claude Code",
        Kind.ApiKey => "Ключ API",
        Kind.Local => "На компьютере",
        _ => "Сервер OffLoadAI",
    };

    /// <summary>Куда уходят сведения о файлах — для согласия: у каждого варианта своё.</summary>
    public static string Destination(Kind kind) => kind switch
    {
        Kind.ClaudeCode => "в Anthropic (Claude) — через Claude Code на этом компьютере, под вашей учётной записью Claude.",
        Kind.ApiKey => "в Anthropic (Claude) — по вашему ключу API.",
        Kind.Local => "никуда: их читает модель в Ollama на этом компьютере, в интернет они не уходят.",
        _ => "на сервер OffLoadAI, а он передаёт их Claude (Anthropic). Вместе с ними уходит ваш ключ OffLoadAI Pro — в нём номер ключа и имя, которое вы назвали при покупке.",
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

    /// <summary>Человек согласился, что сведения о файлах уходят туда, куда их отправляет выбранный вариант
    /// (<see cref="Destination"/>). Без этого помощник не запускается.</summary>
    public bool Consent => Demo.IsOn || Settings.Get<bool?>(ConsentKey(provider)) == true;

    /// <summary>Дать или отозвать согласие на выбранный вариант. Отозванное действует сразу: начатый вопрос прерывается.</summary>
    public void SetConsent(bool given)
    {
        Settings.Set(ConsentKey(provider), given);
        if (!given) Cancel();
        Raise(nameof(Consent));
    }

    /// <summary>Показывать ли помощнику начало небольших текстовых файлов. По умолчанию — нет: имя, размер и дата
    /// обычно и так говорят, что это за файл, а в тексте бывает то, что уходить не должно.</summary>
    public bool SendsPreviews
    {
        get => Settings.Get<bool?>(PreviewsKey) == true;
        set { Settings.Set(PreviewsKey, value); Raise(); }
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

    /// <summary>Что по советам ушло в Корзину и где лежит теперь — чтобы вернуть здесь же, как в «Разобрать».</summary>
    Dictionary<string, CleanupModel.TrashedItem> trashed = [];
    public bool CanPutBack(string id) => trashed.ContainsKey(id);

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
        trashed = [];
        Stage = StageKind.Scanning;
        Status = "Считаю, что лежит в папке…";
        var previews = SendsPreviews;
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
            // Что можно удалить, решают правила «Разобрать», а не помощник.
            var facts = await Task.Run(() => AssistantFacts.Build(picked, home, previews, AssistantTrash.Current(home).Allows), token);
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
        // Любая другая ошибка (нет claude.exe, ответ не JSON, сбой SDK) — тоже сообщение, а не страница, навсегда «в работе».
        catch (Exception problem) { Fail(problem.Message); }
    }

    void Fail(string message)
    {
        Error = message;
        Status = null;
        Stage = StageKind.Failed;
    }

    public void Cancel() => cancel?.Cancel();

    /// <summary>В Корзину — вернуть можно здесь же или из Корзины, пока её не очистили. Правила OffLoadAI проверяются ещё раз:
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
        var home = app.Rules.Home;
        // Удалить можно только то, что разрешают правила «Разобрать», — что бы ни советовал помощник.
        // Сведения — свежие: файл могли заменить новым с тем же именем.
        var current = item with { Verdict = verdict, Modified = FileSystem.Stat(item.Path)?.Modified ?? item.Modified };
        if (!await Task.Run(() => AssistantTrash.Current(home).Allows(current)))
            return "Удалять OffLoadAI разрешает только то, что создаётся заново, и старые установщики. Это можно убрать в сейф.";
        try
        {
            var (inTrash, identity) = await Task.Run(() => RecycleBin.Trash(item.Path));
            trashed = new Dictionary<string, CleanupModel.TrashedItem>(trashed) { [id] = new CleanupModel.TrashedItem(item.Path, inTrash, item.Bytes, identity) };
            MarkDone(id, "в Корзине");
            app.Space.InvalidateAll();
            return null;
        }
        catch (Exception problem) when (problem is IOException or UnauthorizedAccessException or InvalidOperationException or RecycleBin.RecycleException)
        {
            return problem.Message;
        }
    }

    /// <summary>Вернуть из Корзины на прежнее место то, что туда отправил совет. Ответ — что помешало (null — получилось).</summary>
    public async Task<string?> PutBack(string id, AppModel app)
    {
        if (!trashed.TryGetValue(id, out var item)) return "В Корзине его уже нет.";
        var (back, problems) = await Task.Run(() => CleanupModel.PutBack([item]));
        if (back.Count == 0) return problems.FirstOrDefault() ?? "Вернуть не получилось.";
        trashed = trashed.Where(p => p.Key != id).ToDictionary(p => p.Key, p => p.Value);
        done = done.Where(p => p.Key != id).ToDictionary(p => p.Key, p => p.Value);
        Raise(nameof(Answer));
        app.Space.InvalidateAll();
        return null;
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
            "Win11_24H2_Russian_x64.iso" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Образ установки Windows: скачивается заново с сайта Microsoft, а пока пусть лежит в сейфе — вдруг к нему подключена виртуальная машина."),
            "temp-export" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Временная выгрузка, которую давно не открывали: в сейфе она не мешает, а понадобится — вернёте."),
            "node-v22.11.0-x64.msi" or "ChromeSetup.exe" => new Advice(fact.Id, Importance.Junk, AdviceAction.Trash, "Установщик уже поставленной программы."),
            _ => new Advice(fact.Id, Importance.Important, AdviceAction.Keep, "Личный документ — оставить на месте."),
        }).ToList();
        return new AssistantAnswer("В «Загрузках» из мусора — только установщики. Больше всего места освободят образ Windows, видео, архив с фото и старая выгрузка: их лучше убрать в сейф, документы оставить.",
                                   advice, "Демонстрация");
    }
}
