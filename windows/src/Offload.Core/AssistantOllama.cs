using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Offload.Core;

/// <summary>Помощник на локальной модели через Ollama: ничего не уходит с компьютера, обещание «сети нет» сохраняется.
/// Ollama слушает только этот компьютер (127.0.0.1:11434); другой адрес Offload не принимает.</summary>
public sealed class OllamaAssistant(Func<string?> preferredModel) : IAssistantProvider
{
    public static readonly Uri Endpoint = new("http://127.0.0.1:11434/");
    /// <summary>Модели, которые хорошо держат русский и формат JSON, — в порядке предпочтения, если человек не выбрал свою.</summary>
    static readonly string[] Preferred = ["qwen3", "qwen2.5", "gemma3", "llama3.1", "llama3.2", "mistral"];

    public string Title => "Локальная модель (Ollama)";

    List<string>? models;
    public IReadOnlyList<string> Models => models ?? [];

    public string? Problem()
    {
        models = Installed();
        if (models == null) return "Ollama не запущена. Установите её (ollama.com), запустите и скачайте модель: ollama pull qwen2.5:7b — затем «Проверить снова».";
        if (models.Count == 0) return "В Ollama нет ни одной модели. Скачайте, например: ollama pull qwen2.5:7b — затем «Проверить снова».";
        return null;
    }

    string? Model()
    {
        var list = models ?? Installed() ?? [];
        if (preferredModel() is { Length: > 0 } chosen && list.Contains(chosen)) return chosen;
        return Preferred.Select(p => list.FirstOrDefault(m => m.StartsWith(p, StringComparison.OrdinalIgnoreCase))).FirstOrDefault(m => m != null)
               ?? list.FirstOrDefault();
    }

    static HttpClient Client(TimeSpan timeout) => new() { BaseAddress = Endpoint, Timeout = timeout };

    /// <summary>Установленные модели; null — Ollama не отвечает.</summary>
    static List<string>? Installed()
    {
        try
        {
            using var client = Client(TimeSpan.FromSeconds(3));
            var tags = client.GetFromJsonAsync<JsonObject>("api/tags").GetAwaiter().GetResult();
            return (tags?["models"] as JsonArray)?.Select(m => (string?)m?["name"]).OfType<string>().ToList() ?? [];
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException) { return null; }
    }

    public async Task<AssistantAnswer> Ask(IReadOnlyList<FileFact> facts, string? question, CancellationToken cancel)
    {
        if (Problem() is { } problem) throw new AssistantException(AssistantErrorKind.NotInstalled, problem);
        var model = Model()!;
        var request = new JsonObject
        {
            ["model"] = model,
            ["stream"] = false,
            // Ollama сама держит ответ в схеме (структурированный вывод).
            ["format"] = JsonNode.Parse(AssistantPrompt.Schema),
            ["options"] = new JsonObject { ["temperature"] = 0 },
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = AssistantPrompt.Instructions },
                new JsonObject { ["role"] = "user", ["content"] = AssistantPrompt.User(facts, question, DateTime.Now) },
            },
        };
        JsonObject? reply;
        try
        {
            // Локальная модель на процессоре думает долго: ждём до десяти минут.
            using var client = Client(TimeSpan.FromMinutes(10));
            using var response = await client.PostAsJsonAsync("api/chat", request, cancel);
            if (!response.IsSuccessStatusCode)
                throw new AssistantException(AssistantErrorKind.Failed, $"Ollama ответила ошибкой {(int)response.StatusCode}: {(await response.Content.ReadAsStringAsync(cancel)).Trim()}");
            reply = await response.Content.ReadFromJsonAsync<JsonObject>(cancel);
        }
        catch (TaskCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AssistantException(AssistantErrorKind.TimedOut, "Локальная модель не ответила за десять минут — попробуйте модель поменьше или список короче.");
        }
        catch (HttpRequestException error) { throw new AssistantException(AssistantErrorKind.Failed, "Ollama: " + error.Message); }
        JsonNode? answer;
        try { answer = JsonNode.Parse((string?)reply?["message"]?["content"] ?? ""); }
        catch (JsonException) { answer = null; }
        return AssistantPrompt.Parse(answer, facts, $"{Title}: {model}", null);
    }
}
