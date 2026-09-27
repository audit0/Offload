using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Anthropic;
using Anthropic.Exceptions;
using Anthropic.Models.Messages;

namespace Offload.Core;

/// <summary>Помощник по ключу Anthropic API, который человек вставил сам: Claude Code не нужен, платит он по счёту API.
/// Ключ хранится зашифрованным средствами Windows (DPAPI): прочитать его может только эта учётная запись на этом компьютере.</summary>
public sealed class ApiKeyAssistant(Func<string?> key, string model = "claude-opus-5") : IAssistantProvider
{
    public string Title => "Claude по ключу API";

    public string? Problem() => string.IsNullOrWhiteSpace(key())
        ? "Вставьте ключ Anthropic API (console.anthropic.com → API Keys) — он хранится зашифрованным и только на этом компьютере."
        : null;

    public async Task<AssistantAnswer> Ask(IReadOnlyList<FileFact> facts, string? question, CancellationToken cancel)
    {
        if (key() is not { Length: > 0 } apiKey) throw new AssistantException(AssistantErrorKind.NotSignedIn, Problem()!);
        var client = new AnthropicClient { ApiKey = apiKey };
        var schema = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(AssistantPrompt.Schema)!;
        Message response;
        try
        {
            response = await client.Messages.Create(new MessageCreateParams
            {
                Model = model,
                MaxTokens = 16000,
                System = AssistantPrompt.Instructions,
                // Разложить список по трём корзинам — работа несложная: средних усилий хватает, а ответ быстрее и дешевле.
                OutputConfig = new OutputConfig { Effort = Effort.Medium, Format = new JsonOutputFormat { Schema = schema } },
                Messages = [new() { Role = Role.User, Content = AssistantPrompt.User(facts, question, DateTime.Now) }],
            }, cancel);
        }
        catch (AnthropicUnauthorizedException) { throw new AssistantException(AssistantErrorKind.NotSignedIn, "Ключ API не подошёл — проверьте, что он скопирован целиком и не отозван."); }
        catch (AnthropicRateLimitException) { throw new AssistantException(AssistantErrorKind.Failed, "Слишком много запросов к Claude — подождите минуту и повторите."); }
        catch (AnthropicIOException) { throw new AssistantException(AssistantErrorKind.Failed, "Нет связи с Anthropic — проверьте интернет."); }
        catch (AnthropicApiException problem) { throw new AssistantException(AssistantErrorKind.Failed, "Claude: " + problem.Message); }

        if (response.StopReason == "refusal")
            throw new AssistantException(AssistantErrorKind.BadAnswer, "Claude отказался разбирать этот список. Попробуйте другую папку.");
        var text = string.Concat(response.Content.Select(b => b.Value).OfType<TextBlock>().Select(t => t.Text));
        JsonNode? answer;
        try { answer = JsonNode.Parse(text); }
        catch (JsonException) { answer = null; }
        return AssistantPrompt.Parse(answer, facts, Title, null);
    }

    /// <summary>Ключ — в настройках, зашифрованный для текущей учётной записи Windows.</summary>
    public static string Protect(string key) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(key.Trim()), Entropy, DataProtectionScope.CurrentUser));

    public static string? Unprotect(string? stored)
    {
        if (string.IsNullOrEmpty(stored)) return null;
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser)); }
        catch (Exception ex) when (ex is CryptographicException or FormatException) { return null; }
    }

    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("OffLoadAI assistant key");
}
