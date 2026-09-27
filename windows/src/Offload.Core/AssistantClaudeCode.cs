using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Offload.Core;

/// <summary>Помощник через Claude Code, установленный на этом компьютере: работает под подпиской пользователя,
/// своего ключа и сервера OffLoadAI не нужно.
///
/// Claude Code запускается наглухо: без инструментов (--tools "") — не читает файлы, не запускает команды и не ходит
/// в интернет сам; без настроек и перехватчиков пользователя (--setting-sources project, а папка — пустая временная),
/// без MCP и команд; без сохранения сессии. Вход — учётная запись Claude, как у самого Claude Code.
/// Всё, что он знает, — сведения, которые OffLoadAI передаёт во входном потоке.</summary>
public sealed class ClaudeCodeAssistant(string model = "sonnet") : IAssistantProvider
{
    public string Title => "Claude Code на этом компьютере";
    public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(4);

    public string? Problem() => Runner.Locate("claude") == null
        ? "Claude Code не найден. Установите его (claude.com/claude-code) и войдите своей учётной записью Claude — затем «Проверить снова»."
        : null;

    public async Task<AssistantAnswer> Ask(IReadOnlyList<FileFact> facts, string? question, CancellationToken cancel)
    {
        if (Problem() is { } problem) throw new AssistantException(AssistantErrorKind.NotInstalled, problem);
        var scratch = Path.Combine(Path.GetTempPath(), "offloadai-assistant-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
        try
        {
            using var process = Runner.MakeProcess("claude",
            [
                "-p", "--output-format", "json", "--model", model,
                "--tools", "", "--setting-sources", "project", "--strict-mcp-config", "--disable-slash-commands",
                "--no-session-persistence", "--permission-mode", "dontAsk",
                "--system-prompt", AssistantPrompt.Instructions, "--json-schema", AssistantPrompt.Schema,
            ], redirectStdin: true);
            process.StartInfo.WorkingDirectory = scratch;
            process.StartInfo.StandardOutputEncoding = Encoding.UTF8;
            // Вложенный запуск из другой сессии Claude Code и чужой прокси не должны мешать: вход — подписка пользователя.
            foreach (var name in new[] { "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_BASE_URL" }) process.StartInfo.Environment.Remove(name);
            process.StartInfo.Environment["CLAUDE_CODE_ENTRYPOINT"] = "offloadai";
            process.Start();
            var output = process.StandardOutput.ReadToEndAsync(cancel);
            var errors = process.StandardError.ReadToEndAsync(cancel);
            var input = Encoding.UTF8.GetBytes(AssistantPrompt.User(facts, question, DateTime.Now));
            try
            {
                await process.StandardInput.BaseStream.WriteAsync(input, cancel);
                process.StandardInput.Close();
            }
            catch (IOException) { }

            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            limit.CancelAfter(Timeout);
            try { await process.WaitForExitAsync(limit.Token); }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                cancel.ThrowIfCancellationRequested();
                throw new AssistantException(AssistantErrorKind.TimedOut, "Помощник не ответил за четыре минуты. Попробуйте список поменьше.");
            }
            return Read(await output, await errors, facts);
        }
        finally
        {
            try { Directory.Delete(scratch, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    internal AssistantAnswer Read(string output, string errors, IReadOnlyList<FileFact> facts)
    {
        JsonNode? result;
        try { result = JsonNode.Parse(output); }
        catch (JsonException) { result = null; }
        if (result is not JsonObject root)
            throw new AssistantException(AssistantErrorKind.Failed, "Claude Code не ответил: " + FirstLine(errors.Length > 0 ? errors : output));
        var text = (string?)root["result"] ?? "";
        if ((bool?)root["is_error"] == true)
        {
            var signIn = text.Contains("login", StringComparison.OrdinalIgnoreCase) || text.Contains("API key", StringComparison.OrdinalIgnoreCase)
                         || text.Contains("authenticat", StringComparison.OrdinalIgnoreCase);
            throw signIn
                ? new AssistantException(AssistantErrorKind.NotSignedIn, "Claude Code не вошёл в учётную запись. Откройте терминал, запустите claude и войдите (/login) — затем «Проверить снова».")
                : new AssistantException(AssistantErrorKind.Failed, "Claude Code: " + FirstLine(text));
        }
        decimal? cost = root["total_cost_usd"] is JsonValue value && value.TryGetValue<decimal>(out var usd) ? usd : null;
        var structured = root["structured_output"];
        if (structured == null)
        {
            try { structured = JsonNode.Parse(text); }
            catch (JsonException) { }
        }
        return AssistantPrompt.Parse(structured, facts, Title, cost);
    }

    static string FirstLine(string text) => text.Trim().Split('\n').FirstOrDefault()?.Trim() is { Length: > 0 } line
        ? (line.Length > 200 ? line[..200] + "…" : line) : "без объяснений";
}
