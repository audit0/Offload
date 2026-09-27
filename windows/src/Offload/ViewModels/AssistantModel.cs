using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>AI-помощник по файлам: смотрит на содержимое папки и говорит, что важно, что менее важно, а что мусор.
/// Сам ничего не делает — каждый совет выполняет человек, теми же путями, что и без помощника.</summary>
public sealed class AssistantModel : Observable
{
    public enum StageKind { Idle, Scanning, Thinking, Done, Failed }

    const string ConsentKey = "assistant.consent";

    public IAssistantProvider Provider { get; } = new ClaudeCodeAssistant();

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
            if (Demo.IsOn) measured = Demo.SpaceItems();
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

    /// <summary>Ответ для снимков и демонстрации: без сети, по вымышленным папкам.</summary>
    static AssistantAnswer DemoAnswer(IReadOnlyList<FileFact> facts)
    {
        var advice = facts.Select(fact => Paths.Name(fact.Path) switch
        {
            "AppData" => new Advice(fact.Id, Importance.Important, AdviceAction.Keep, "Данные программ: без них они не запустятся."),
            "Downloads" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Скачанное: в основном дистрибутивы и архивы — нужны редко."),
            "Videos" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Старые съёмки: смотрят редко, место занимают больше всего."),
            "Pictures" or "Documents" => new Advice(fact.Id, Importance.Important, AdviceAction.Keep, "Личные документы и фото — незаменимы."),
            "Projects" => new Advice(fact.Id, Importance.Important, AdviceAction.Keep, "Рабочие проекты с git — с ними работают каждый день."),
            "Music" => new Advice(fact.Id, Importance.Minor, AdviceAction.Safe, "Музыка: можно держать в сейфе и возвращать по надобности."),
            _ => new Advice(fact.Id, Importance.Junk, AdviceAction.Trash, "Временные файлы — программы создадут их заново."),
        }).ToList();
        return new AssistantAnswer("Больше всего места занимают старые видео и загрузки — их можно убрать в сейф и освободить около 200 ГБ. Документы, фото и проекты лучше оставить.",
                                   advice, "Демонстрация");
    }
}
