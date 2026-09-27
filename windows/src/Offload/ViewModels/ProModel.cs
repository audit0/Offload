using System.Globalization;
using System.IO;
using System.Reflection;
using Offload.Core;

namespace Offload;

/// <summary>OffLoadAI Pro на этом компьютере: ключ, пробные две недели, ранние пользователи.
///
/// Ключ проверяется подписью, без сети; он тот же, что у версии для Mac. Всё хранится в настройках программы;
/// сбросить пробу, удалив их, можно — Pro держится на честности тех, кому OffLoadAI полезен, а не на защите.</summary>
public sealed class ProModel : Observable
{
    /// <summary>Где купить: бот в Telegram — оплата Stars, криптовалютой или по СБП, ключ приходит сообщением.</summary>
    public const string PurchaseUrl = "https://t.me/OffLoadAIbot?start=pro";
    /// <summary>Цена — одной строкой здесь и в README («OffLoadAI Pro»).</summary>
    public const string Price = "1 490 ₽ или $19 — один раз";
    public const string Terms = "Ключ работает всегда. Новые версии — год, дальше продление за полцены; не продлили — остаётся последняя версия того года.";

    const string LicenseKey = "pro.license";
    const string TrialKey = "pro.trialStarted";
    const string EarlyKey = "pro.early";

    /// <summary>День выхода этой версии: ключ открывает версии, вышедшие до конца его обновлений. Пишется в сборку
    /// (scripts\build.ps1, по дате последнего коммита); у сборки из исходников его нет — тогда ключ подходит любой.</summary>
    public static readonly DateTime? ReleaseDate = LicenseCodec.Day(Assembly.GetExecutingAssembly()
        .GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "OffloadReleaseDate")?.Value);

    ProStatus status = ProStatus.Free;
    public ProStatus Status { get => status; private set { if (Set(ref status, value)) Raise(nameof(IsPro), nameof(Summary)); } }
    public bool IsPro => Status.IsPro;
    License? license;

    string? keyProblem;
    /// <summary>Ключ не подошёл — почему, одной фразой.</summary>
    public string? KeyProblem { get => keyProblem; set => Set(ref keyProblem, value); }

    /// <summary>Попросили окно «OffLoadAI Pro» — из-за конкретной возможности (или просто так, null). Его открывает главное окно.</summary>
    public event Action<ProFeature?>? Offered;

    public ProModel()
    {
        if (Demo.IsOn)
        {
            // Снимки для README показывают всё, что умеет программа. OFFLOAD_DEMO_PRO=free или trial — как это выглядит без ключа.
            status = Environment.GetEnvironmentVariable("OFFLOAD_DEMO_PRO") switch
            {
                "free" => ProStatus.Free,
                "trial" => ProStatus.Trial(9),
                _ => ProStatus.Early,
            };
            return;
        }
        if (Settings.Get<bool?>(EarlyKey) == null)
        {
            // Первый запуск версии с Pro. Кто пользовался OffLoadAI раньше, получает всё, что было, навсегда:
            // забирать то, чем человек уже пользовался бесплатно, нечестно.
            var early = UsedBefore();
            Settings.Set(EarlyKey, early);
            if (!early) Settings.Set(TrialKey, DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
        }
        if (Settings.Get<string>(LicenseKey) is { } text)
        {
            try { license = LicenseCodec.Verify(text); }
            catch (LicenseException) { }
        }
        Refresh();
    }

    public bool Allows(ProFeature feature) => Status.IsPro;

    /// <summary>Сохранённый ключ как есть — им помощник входит на сервер OffLoadAI.</summary>
    public string? LicenseText => license != null ? Settings.Get<string>(LicenseKey) : null;

    /// <summary>Открыть окно «OffLoadAI Pro» — из-за конкретной возможности или просто так.</summary>
    public void Offer(ProFeature? feature = null)
    {
        KeyProblem = null;
        Offered?.Invoke(feature);
    }

    /// <summary>Пробный период считается днями: окно могло простоять открытым со вчера.</summary>
    public void Refresh()
    {
        if (Demo.IsOn) return;
        DateTime? started = DateTime.TryParse(Settings.Get<string>(TrialKey), CultureInfo.InvariantCulture,
                                              DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var date) ? date : null;
        Status = ProStatus.Resolve(license, ReleaseDate, Settings.Get<bool?>(EarlyKey) == true, started, DateTime.UtcNow);
    }

    /// <summary>Проверить и запомнить ключ. Ответ — подошёл ли.</summary>
    public bool Activate(string text)
    {
        try
        {
            var checkedLicense = LicenseCodec.Verify(text);
            if (!checkedLicense.Covers(ReleaseDate))
            {
                KeyProblem = $"Ключ верный, но его обновления закончились {Day(checkedLicense.UpdatesUntil)}, а эта версия вышла позже. Продлите ключ — или поставьте версию, вышедшую до этой даты: с ней ключ работает всегда.";
                return false;
            }
            license = checkedLicense;
            KeyProblem = null;
            Settings.Set(LicenseKey, new string(text.Where(c => !char.IsWhiteSpace(c)).ToArray()));
            if (Demo.IsOn) Status = new ProStatus(ProStatusKind.Licensed, checkedLicense);
            Refresh();
            return true;
        }
        catch (LicenseException error)
        {
            KeyProblem = error.Message;
            return false;
        }
    }

    /// <summary>Убрать ключ с этого компьютера — например, перед его продажей. Ключ остаётся у владельца.</summary>
    public void RemoveLicense()
    {
        license = null;
        Settings.Set<string?>(LicenseKey, null);
        Refresh();
    }

    /// <summary>Одной строкой — для боковой колонки.</summary>
    public string Summary => Status.Kind switch
    {
        ProStatusKind.Licensed => "OffLoadAI Pro",
        ProStatusKind.Early => "Pro — ранний пользователь",
        ProStatusKind.Trial => $"Pro: пробный, {Status.DaysLeft} {Plural.Ru(Status.DaysLeft, "день", "дня", "дней")}",
        ProStatusKind.Expired => "Pro: продлите ключ",
        _ => "Бесплатная версия",
    };

    public static string Day(DateTime date) => date.ToString("d MMMM yyyy 'г.'", CultureInfo.GetCultureInfo("ru-RU"));

    /// <summary>Остались ли следы прежних версий: база решений, журнал переносов или настройки.</summary>
    static bool UsedBefore()
    {
        if (File.Exists(DecisionStore.DefaultPath) || File.Exists(Journal.LocalPath)) return true;
        return new[] { "storeMode", "backup.sources", "backup.destination" }.Any(key => Settings.Get<System.Text.Json.Nodes.JsonNode>(key) != null);
    }
}
