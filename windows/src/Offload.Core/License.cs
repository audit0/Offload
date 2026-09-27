using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Offload.Core;

/// <summary>OffLoadAI Pro: что в нём и как проверяется ключ. Всё — как у версии для Mac, ключ один на обе.
///
/// Правила, из которых всё остальное:
/// - Ключ проверяется на этом компьютере, без сети: подпись Ed25519 над содержимым ключа.
///   OffLoadAI не ходит на сервер ни при покупке, ни при запуске.
/// - Pro никогда не стоит между человеком и его данными. Сейф, перенос со сверкой, возврат
///   перенесённого, возврат тома Docker, восстановление из iCloud, ключи и токены в сейф,
///   очистка мусора — бесплатны всегда. Pro — это удобство и инструменты сверху.
/// - Кончилась проба посреди работы — начатое доделывается; ограничение действует только на новое «да».</summary>
public enum ProFeature
{
    /// <summary>«Удалить лишние копии?» в разборе.</summary>
    Duplicates,
    /// <summary>Привычки: похожее само попадает в нужный вопрос.</summary>
    Habits,
    /// <summary>Обновляемый бэкап проектов и вопрос «Добавить проекты в бэкап?».</summary>
    ProjectBackup,
    /// <summary>Упаковать тома Docker в сейф и убрать из Docker. Вернуть том — бесплатно.</summary>
    DockerVolumes,
}

public static class ProFeatures
{
    public static readonly ProFeature[] All = Enum.GetValues<ProFeature>();

    public static string Title(this ProFeature feature) => feature switch
    {
        ProFeature.Duplicates => "Лишние копии",
        ProFeature.Habits => "Привычки",
        ProFeature.ProjectBackup => "Бэкап проектов",
        _ => "Тома Docker в сейф",
    };

    public static string Detail(this ProFeature feature) => feature switch
    {
        ProFeature.Duplicates => "Одинаковые файлы находятся по SHA-256, одна копия остаётся всегда, лишние уходят в Корзину.",
        ProFeature.Habits => "OffLoadAI учится на ваших ответах и сам кладёт похожее в нужный вопрос.",
        ProFeature.ProjectBackup => "Обновляемая копия папок с проектами в сейф: копируется только изменённое.",
        _ => "Неиспользуемые тома упаковываются в сейф со сверкой каждого файла.",
    };
}

public static class ProQuestions
{
    /// <summary>Для «да» на этот вопрос нужен OffLoadAI Pro. «Не сейчас» и всё найденное видно и без него.</summary>
    public static ProFeature? ProFeature(this QuestionKind kind) => kind.Type != QuestionKindType.Module ? null : kind.Module switch
    {
        CleanupModule.Duplicates => Core.ProFeature.Duplicates,
        CleanupModule.Projects => Core.ProFeature.ProjectBackup,
        _ => null,
    };
}

/// <summary>Проверенный ключ: кому выдан и до какой даты выходящие версии им открываются.</summary>
/// <param name="Id">Номер ключа — по нему ключ находят в списке выданных (возврат денег, замена).</param>
/// <param name="Name">Как ключ подписан в окне «OffLoadAI Pro»: имя или ник покупателя.</param>
/// <param name="UpdatesUntil">Версии, вышедшие до этой даты, открываются ключом навсегда; вышедшие позже — нужно продлить.</param>
public sealed record License(string Id, string Name, DateTime Issued, DateTime UpdatesUntil)
{
    /// <summary>Открывает ли ключ версию, вышедшую в этот день. Без даты (сборка из исходников) — открывает.</summary>
    public bool Covers(DateTime? release) => release == null || release.Value <= UpdatesUntil;
}

public enum LicenseErrorKind { Malformed, BadSignature, UnsupportedVersion }

public sealed class LicenseException(LicenseErrorKind kind) : Exception(kind switch
{
    LicenseErrorKind.Malformed => "Это не похоже на ключ OffLoadAI Pro. Скопируйте его целиком, вместе с «OFFLOAD-».",
    LicenseErrorKind.BadSignature => "Ключ не подходит: подпись не сходится. Возможно, в нём опечатка — скопируйте его заново.",
    _ => "Ключ выпущен для более новой версии OffLoadAI. Обновите программу.",
})
{
    public LicenseErrorKind Kind { get; } = kind;
}

/// <summary>Формат ключа: <c>OFFLOAD-&lt;содержимое&gt;.&lt;подпись&gt;</c>, обе части — base64url без «=».
/// Содержимое — JSON с полями v, id, name, issued, until (даты — ISO 8601, день).
/// Пробелы и переносы строк внутри ключа игнорируются: письма и мессенджеры любят их вставлять.</summary>
public static class LicenseCodec
{
    public const string Prefix = "OFFLOAD-";
    const int FormatVersion = 1;

    /// <summary>Открытый ключ OffLoadAI — тот же, что у версии для Mac: им проверяются все ключи Pro.
    /// Закрытый — только у автора, не в репозитории.</summary>
    public const string PublicKey = "s634ae2EoVpINNy36tMkbki6WfhiKR0l6BFw9flW78U";

    sealed class Payload
    {
        [JsonPropertyName("v")] public int V { get; set; }
        [JsonPropertyName("id")] public string? Id { get; set; }
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("issued")] public string? Issued { get; set; }
        [JsonPropertyName("until")] public string? Until { get; set; }
    }

    public static License Verify(string text, string publicKey = PublicKey)
    {
        var compact = new string(text.Where(c => !char.IsWhiteSpace(c)).ToArray());
        if (!compact.StartsWith(Prefix, StringComparison.Ordinal)) throw new LicenseException(LicenseErrorKind.Malformed);
        var parts = compact[Prefix.Length..].Split('.');
        if (parts.Length != 2 || FromBase64Url(parts[0]) is not { } body || FromBase64Url(parts[1]) is not { } signature
            || FromBase64Url(publicKey) is not { Length: 32 } key)
            throw new LicenseException(LicenseErrorKind.Malformed);
        // Подпись — над байтами содержимого как они есть, до разбора JSON.
        if (!ValidSignature(key, body, signature)) throw new LicenseException(LicenseErrorKind.BadSignature);
        Payload? payload;
        try { payload = JsonSerializer.Deserialize<Payload>(body); }
        catch (JsonException) { throw new LicenseException(LicenseErrorKind.Malformed); }
        if (payload?.Id == null || payload.Name == null) throw new LicenseException(LicenseErrorKind.Malformed);
        if (payload.V != FormatVersion) throw new LicenseException(LicenseErrorKind.UnsupportedVersion);
        if (Day(payload.Issued) is not { } issued || Day(payload.Until) is not { } until) throw new LicenseException(LicenseErrorKind.Malformed);
        return new License(payload.Id, payload.Name, issued, until);
    }

    static bool ValidSignature(byte[] key, byte[] body, byte[] signature)
    {
        if (signature.Length != 64) return false;
        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(key));
            verifier.BlockUpdate(body, 0, body.Length);
            return verifier.VerifySignature(signature);
        }
        catch (ArgumentException) { return false; }
    }

    /// <summary>Выпуск ключа — только у автора, с закрытым ключом. Здесь — для проверок: содержимое то же,
    /// байт в байт, что выпускает версия для Mac (ключи по алфавиту, кириллица без экранирования).</summary>
    public static string Issue(License license, Ed25519PrivateKeyParameters privateKey)
    {
        var body = Body(license);
        var signer = new Ed25519Signer();
        signer.Init(true, privateKey);
        signer.BlockUpdate(body, 0, body.Length);
        return Prefix + ToBase64Url(body) + "." + ToBase64Url(signer.GenerateSignature());
    }

    internal static byte[] Body(License license)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteString("id", license.Id);
            writer.WriteString("issued", DayString(license.Issued));
            writer.WriteString("name", license.Name);
            writer.WriteString("until", DayString(license.UpdatesUntil));
            writer.WriteNumber("v", FormatVersion);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    public static DateTime? Day(string? text) =>
        text != null && DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                               DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var day)
            ? DateTime.SpecifyKind(day, DateTimeKind.Utc) : null;

    public static string DayString(DateTime day) => day.ToUniversalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>base64url без «=»: только буквы и цифры ASCII, «-» и «_» — иначе null.</summary>
    public static byte[]? FromBase64Url(string text)
    {
        if (!text.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) return null;
        var base64 = text.Replace('-', '+').Replace('_', '/');
        base64 += new string('=', (4 - base64.Length % 4) % 4);
        try { return Convert.FromBase64String(base64); }
        catch (FormatException) { return null; }
    }

    public static string ToBase64Url(byte[] data) => Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

public enum ProStatusKind
{
    Licensed,
    /// <summary>Ключ есть, но эта версия вышла после конца его обновлений: работает прежняя, эту — продлить.</summary>
    Expired,
    /// <summary>Пользовался OffLoadAI до появления Pro: всё, что было, остаётся открытым.</summary>
    Early,
    Trial,
    Free,
}

/// <summary>Что открыто на этом компьютере: ключ, проба, ранний пользователь или бесплатная версия.</summary>
public readonly record struct ProStatus(ProStatusKind Kind, License? License = null, int DaysLeft = 0)
{
    public bool IsPro => Kind is ProStatusKind.Licensed or ProStatusKind.Early or ProStatusKind.Trial;

    /// <summary>Сколько дней пробы, считая с первого запуска версии с Pro.</summary>
    public const int TrialDays = 14;

    public static readonly ProStatus Free = new(ProStatusKind.Free);
    public static readonly ProStatus Early = new(ProStatusKind.Early);
    public static ProStatus Trial(int daysLeft) => new(ProStatusKind.Trial, DaysLeft: daysLeft);

    /// <summary>Итог по ключу, дате выхода этой версии и началу пробы. Ключ, который не подходит к этой
    /// версии, пробу не отнимает: человек заплатил и точно не хуже того, кто не платил.</summary>
    public static ProStatus Resolve(License? license, DateTime? release, bool early, DateTime? trialStarted, DateTime now)
    {
        if (license != null && license.Covers(release)) return new(ProStatusKind.Licensed, license);
        if (early) return Early;
        if (trialStarted is { } started)
        {
            // Полные сутки с начала пробы; часы, переведённые назад, пробу не удлиняют.
            var days = (int)(now.ToUniversalTime() - started.ToUniversalTime()).TotalDays;
            var left = TrialDays - Math.Max(days, 0);
            if (left > 0) return Trial(left);
        }
        return license != null ? new(ProStatusKind.Expired, license) : Free;
    }
}
