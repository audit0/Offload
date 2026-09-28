using System.Net;
using System.Text.Json;

namespace Offload.Core;

/// <summary>
/// Сообщение о новой версии — только если человек его включил.
///
/// Раз в сутки OffLoadAI спрашивает у GitHub номер последнего выпуска. В запросе нет ничего о компьютере,
/// файлах и версии программы: GitHub видит только адрес сети, как при открытии любой страницы.
/// Скачивает и ставит обновление сам человек — той же командой установки, что сверяет архив.
/// </summary>
public static class UpdateCheck
{
    public static readonly Uri Endpoint = new("https://api.github.com/repos/audit0/Offload/releases/latest");
    public static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    /// <summary>Выпуск: три числа без «v».</summary>
    public sealed record Release(string Version)
    {
        /// <summary>Страница выпуска строится из номера, а не берётся из ответа: другой адрес программа не откроет.</summary>
        public string Page => "https://github.com/audit0/Offload/releases/tag/v" + Version;
    }

    public sealed class UpdateException(string message) : Exception(message);

    /// <summary>Разбор ответа GitHub. Черновики, предварительные выпуски и непонятные номера не считаются.</summary>
    public static Release Parse(string json)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(json); }
        catch (JsonException) { throw new UpdateException("GitHub ответил не так, как ожидалось."); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new UpdateException("GitHub ответил не так, как ожидалось.");
            bool Flag(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
            string? tag = root.TryGetProperty("tag_name", out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
            if (Flag("draft") || Flag("prerelease") || tag == null || Numbers(tag.StartsWith('v') ? tag[1..] : tag, strict: true) is not { } numbers)
                throw new UpdateException("У последнего выпуска на GitHub непонятный номер версии.");
            return new Release(string.Join('.', numbers));
        }
    }

    /// <summary>Новее ли <paramref name="candidate"/>, чем <paramref name="current"/>. Номер сборки для разработки
    /// (0.4.0-ci) сравнивается по трём числам; непонятный номер — не новее: лучше промолчать, чем звать обновляться зря.</summary>
    public static bool IsNewer(string candidate, string current)
    {
        if (Numbers(candidate, strict: true) is not { } next || Numbers(current, strict: false) is not { } now) return false;
        for (int i = 0; i < 3; i++)
            if (next[i] != now[i]) return next[i] > now[i];
        return false;
    }

    /// <summary>Пора ли спросить снова: раз в сутки. Часы, переведённые назад, проверку не останавливают.</summary>
    public static bool IsDue(DateTime? lastCheck, DateTime now) => lastCheck is not { } last || now < last || now - last >= Interval;

    /// <summary>Спросить GitHub о последнем выпуске. Без cookies и номера этой версии в запросе.</summary>
    public static async Task<Release> FetchAsync(CancellationToken cancel = default)
    {
        using var handler = new HttpClientHandler { UseCookies = false };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("OffLoadAI");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        HttpResponseMessage response;
        try { response = await http.SendAsync(request, cancel); }
        catch (HttpRequestException e) { throw new UpdateException("Нет связи с GitHub: " + e.Message); }
        catch (TaskCanceledException) when (!cancel.IsCancellationRequested) { throw new UpdateException("GitHub не ответил вовремя."); }
        using (response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
                throw new UpdateException($"GitHub не ответил на вопрос о версии (код {(int)response.StatusCode}).");
            return Parse(await response.Content.ReadAsStringAsync(cancel));
        }
    }

    /// <summary>«1.2.3» → [1, 2, 3]. Строго — только три числа; иначе допускается хвост сборки: 1.2.3-ci, 1.2.3.4.</summary>
    internal static int[]? Numbers(string text, bool strict)
    {
        var head = text;
        if (!strict && text.IndexOfAny(['-', '+']) is var cut and >= 0) head = text[..cut];
        var parts = head.Split('.');
        if (parts.Length != 3 && (strict || parts.Length < 3)) return null;
        var result = new int[3];
        for (int i = 0; i < 3; i++)
        {
            var part = parts[i];
            if (part.Length is 0 or > 6 || !part.All(char.IsAsciiDigit)) return null;
            result[i] = int.Parse(part);
        }
        return result;
    }
}
