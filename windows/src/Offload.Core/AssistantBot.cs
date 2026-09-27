using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Offload.Core;

/// <summary>Помощник через сервер OffLoadAI (тот же, что у бота @OffLoadAIbot): ни Claude Code, ни ключа API не нужно —
/// доступ открывает ключ Offload Pro. Сервер сам добавляет инструкции и схему и зовёт модель; программа отправляет
/// ровно то же сообщение со сведениями о файлах, что и другим вариантам.
///
/// Договор с сервером (версия 1):
///   POST {адрес}/v1/assistant, заголовок Authorization: Bearer &lt;ключ Offload Pro&gt;,
///   тело {"v":1,"client":"offloadai-windows/&lt;версия&gt;","input":"&lt;сообщение со сведениями&gt;"}.
///   Ответ 200: {"answer":{"summary":…,"items":[…]},"remaining":&lt;сколько вопросов осталось&gt;}.
///   Ошибки: 401 — ключ не подошёл, 402 — нужен Pro или кончились вопросы, 429 — слишком часто; тело {"error":"&lt;фраза для человека&gt;"}.</summary>
public sealed class BotAssistant(Func<string?> license, Func<string?> endpoint, string client) : IAssistantProvider
{
    public string Title => "Сервер OffLoadAI";

    public string? Problem()
    {
        if (Endpoint() == null) return "Помощник через сервер OffLoadAI ещё не запущен — он появится в одном из обновлений. Пока выберите другой вариант.";
        if (string.IsNullOrWhiteSpace(license())) return "Помощник через сервер OffLoadAI входит в Offload Pro: введите ключ в окне «Offload Pro».";
        return null;
    }

    /// <summary>Только https: сведения о файлах не должны идти по сети открытым текстом.</summary>
    Uri? Endpoint() => Uri.TryCreate(endpoint(), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps ? uri : null;

    public async Task<AssistantAnswer> Ask(IReadOnlyList<FileFact> facts, string? question, CancellationToken cancel)
    {
        if (Problem() is { } problem) throw new AssistantException(AssistantErrorKind.NotInstalled, problem);
        using var http = new HttpClient { BaseAddress = Endpoint(), Timeout = TimeSpan.FromMinutes(4) };
        using var request = new HttpRequestMessage(HttpMethod.Post, "v1/assistant")
        {
            Content = JsonContent.Create(new JsonObject { ["v"] = 1, ["client"] = client, ["input"] = AssistantPrompt.User(facts, question, DateTime.Now) }),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", license()!.Trim());
        JsonObject? body;
        HttpResponseMessage response;
        try
        {
            response = await http.SendAsync(request, cancel);
            try { body = await response.Content.ReadFromJsonAsync<JsonObject>(cancel); }
            catch (JsonException) { body = null; }
        }
        catch (TaskCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AssistantException(AssistantErrorKind.TimedOut, "Сервер OffLoadAI не ответил за четыре минуты — попробуйте позже.");
        }
        catch (HttpRequestException) { throw new AssistantException(AssistantErrorKind.Failed, "Нет связи с сервером OffLoadAI — проверьте интернет."); }
        using (response)
        {
            var said = (string?)body?["error"];
            switch ((int)response.StatusCode)
            {
                case 200: break;
                case 401: throw new AssistantException(AssistantErrorKind.NotSignedIn, said ?? "Сервер не принял ключ Offload Pro.");
                case 402: throw new AssistantException(AssistantErrorKind.NotSignedIn, said ?? "Нужен Offload Pro, или вопросы на этот месяц закончились.");
                case 429: throw new AssistantException(AssistantErrorKind.Failed, said ?? "Слишком много вопросов подряд — подождите минуту.");
                default: throw new AssistantException(AssistantErrorKind.Failed, said ?? $"Сервер OffLoadAI ответил ошибкой {(int)response.StatusCode}.");
            }
        }
        return AssistantPrompt.Parse(body?["answer"], facts, Title, null);
    }
}
