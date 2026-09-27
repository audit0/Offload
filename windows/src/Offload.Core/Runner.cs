using System.Diagnostics;
using System.Text;

namespace Offload.Core;

/// <summary>Результат запуска внешней программы.</summary>
public sealed record CommandResult(int Status, byte[] Stdout, string Stderr)
{
    public string Output => Encoding.UTF8.GetString(Stdout);
    public bool Succeeded => Status == 0;
}

public enum RunnerErrorKind { ToolNotFound, TimedOut, Failed }

public sealed class RunnerException : Exception
{
    public RunnerErrorKind Kind { get; }
    public string Tool { get; }
    public int Status { get; }

    public RunnerException(RunnerErrorKind kind, string tool, int status = 0, string message = "")
        : base(Describe(kind, tool, status, message))
    {
        Kind = kind;
        Tool = tool;
        Status = status;
    }

    static string Describe(RunnerErrorKind kind, string tool, int status, string message) => kind switch
    {
        RunnerErrorKind.ToolNotFound => $"Не найдена программа «{tool}».",
        RunnerErrorKind.TimedOut => $"Программа «{tool}» не ответила вовремя.",
        _ => $"«{tool}» завершилась с кодом {status}: {message}",
    };
}

/// <summary>
/// Запуск внешних программ без оболочки.
///
/// Аргументы всегда передаются списком (ArgumentList): пробелы, кавычки, <c>&amp;</c> и <c>|</c> в путях
/// и именах не могут превратиться в команды. PATH окружения не используется: программы ищутся
/// только в известных каталогах, а системные — только в System32, куда без прав администратора не пишут.
/// </summary>
public static class Runner
{
    static string SystemRoot => Environment.GetFolderPath(Environment.SpecialFolder.Windows);
    static string System32 => Environment.SystemDirectory;

    /// <summary>Системные программы и где они лежат внутри System32.</summary>
    static readonly Dictionary<string, string> SystemTools = new(StringComparer.OrdinalIgnoreCase)
    {
        ["powershell"] = @"WindowsPowerShell\v1.0\powershell.exe",
        ["ssh-keygen"] = @"OpenSSH\ssh-keygen.exe",
        ["tar"] = "tar.exe",
        ["cmd"] = "cmd.exe",
        ["whoami"] = "whoami.exe",
        ["wsl"] = "wsl.exe",
        ["where"] = "where.exe",
        ["attrib"] = "attrib.exe",
        ["defrag"] = "defrag.exe",
    };

    /// <summary>Сторонние инструменты. Их каталоги часто доступны пользователю на запись,
    /// поэтому системные программы оттуда никогда не берутся.</summary>
    public static readonly HashSet<string> ThirdPartyTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "docker", "zstd", "restic", "VBoxManage", "claude",
    };

    public static IReadOnlyList<string> ThirdPartyDirectories
    {
        get
        {
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            return
            [
                Path.Combine(programFiles, @"Docker\Docker\resources\bin"),
                Path.Combine(local, @"Microsoft\WinGet\Links"),
                Path.Combine(programFiles, @"WinGet\Links"),
                Path.Combine(profile, @"scoop\shims"),
                Path.Combine(programData, @"chocolatey\bin"),
                Path.Combine(programFiles, "restic"),
                Path.Combine(programFiles, "zstd"),
                Path.Combine(programFiles, "Oracle", "VirtualBox"),
                // Claude Code: установщик Anthropic кладёт его в ~\.local\bin, npm — внутрь своего пакета
                // (claude.cmd рядом — обёртка через cmd.exe, её не запускаем: аргументы через cmd небезопасны).
                Path.Combine(profile, @".local\bin"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"npm\node_modules\@anthropic-ai\claude-code\bin"),
            ];
        }
    }

    /// <summary>Переопределение для проверок: подложить свою программу вместо настоящей.</summary>
    public static Func<string, string?>? LocateOverride { get; set; }

    public static string? Locate(string name)
    {
        if (LocateOverride?.Invoke(name) is { } overridden) return overridden;
        if (string.IsNullOrEmpty(name) || name.IndexOfAny(['\\', '/', ':']) >= 0) return null;
        if (SystemTools.TryGetValue(name, out var relative))
        {
            var path = Path.Combine(System32, relative);
            return File.Exists(path) ? path : null;
        }
        if (!ThirdPartyTools.Contains(name)) return null;
        foreach (var directory in ThirdPartyDirectories)
        {
            var path = Path.Combine(directory, name + ".exe");
            if (File.Exists(path)) return path;
        }
        // winget ставит программы без ярлыка в свою папку пакетов: …\Packages\restic.restic_…\restic_0.17.3_windows_amd64.exe
        if (name.Equals("restic", StringComparison.OrdinalIgnoreCase) || name.Equals("zstd", StringComparison.OrdinalIgnoreCase))
        {
            var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WinGet\Packages");
            try
            {
                foreach (var folder in Directory.EnumerateDirectories(packages, "*" + name + "*"))
                {
                    var found = Directory.EnumerateFiles(folder, name + "*.exe", SearchOption.AllDirectories)
                        .OrderBy(p => p.Length).FirstOrDefault();
                    if (found != null) return found;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return null;
    }

    /// <summary>Окружение для запускаемых программ: как у OffLoadAI, но PATH — только известные каталоги.</summary>
    public static Dictionary<string, string> ChildEnvironment
    {
        get
        {
            var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
                env[(string)entry.Key] = (string?)entry.Value ?? "";
            env["PATH"] = string.Join(';', new[] { System32, SystemRoot, Path.Combine(System32, "Wbem"),
                Path.Combine(System32, @"WindowsPowerShell\v1.0"), Path.Combine(System32, "OpenSSH") }.Concat(ThirdPartyDirectories));
            return env;
        }
    }

    /// <summary>Готовит процесс, не запуская его. Нужен для конвейеров вроде docker → zstd.</summary>
    public static Process MakeProcess(string tool, IEnumerable<string> arguments, bool redirectStdin = false,
                                      bool redirectStdout = true, bool redirectStderr = true)
    {
        var executable = Locate(tool) ?? throw new RunnerException(RunnerErrorKind.ToolNotFound, tool);
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = redirectStdin,
            RedirectStandardOutput = redirectStdout,
            RedirectStandardError = redirectStderr,
            StandardErrorEncoding = redirectStderr ? Encoding.UTF8 : null,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        info.Environment.Clear();
        foreach (var (key, value) in ChildEnvironment) info.Environment[key] = value;
        return new Process { StartInfo = info };
    }

    public static CommandResult Run(string tool, IEnumerable<string> arguments, byte[]? stdin = null, TimeSpan? timeout = null,
                                    string? currentDirectory = null)
    {
        using var process = MakeProcess(tool, arguments, redirectStdin: true);
        if (currentDirectory != null) process.StartInfo.WorkingDirectory = currentDirectory;
        process.Start();
        // Оба канала читаются параллельно: иначе большой вывод заполнит буфер и процесс зависнет.
        var output = new MemoryStream();
        var outTask = process.StandardOutput.BaseStream.CopyToAsync(output);
        var errTask = process.StandardError.ReadToEndAsync();
        try
        {
            if (stdin != null) process.StandardInput.BaseStream.Write(stdin);
            process.StandardInput.Close();
        }
        catch (IOException) { }

        if (timeout is { } limit)
        {
            if (!process.WaitForExit(limit))
            {
                // На Windows нет мягкого сигнала: завершаем всё дерево процесса сразу.
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                process.WaitForExit(5000);
                Task.WaitAll([outTask, errTask], TimeSpan.FromSeconds(5));
                throw new RunnerException(RunnerErrorKind.TimedOut, tool);
            }
        }
        process.WaitForExit();
        Task.WaitAll(outTask, errTask);
        return new CommandResult(process.ExitCode, output.ToArray(), errTask.Result);
    }

    /// <summary>Как <see cref="Run"/>, но вывод отдаётся построчно по мере появления, а работу можно прервать.
    /// Нужен долгим командам с прогрессом (restic restore). Возвращённый Stdout пуст:
    /// всё прочитанное уже ушло в onLine. Прерванная работа — <see cref="OperationCanceledException"/>.</summary>
    public static CommandResult Stream(string tool, IEnumerable<string> arguments, byte[]? stdin = null,
                                       Func<bool>? isCancelled = null, Action<string>? onErrorLine = null,
                                       Action<string>? onLine = null)
    {
        isCancelled ??= () => false;
        using var process = MakeProcess(tool, arguments, redirectStdin: true);
        process.StartInfo.StandardOutputEncoding = Encoding.UTF8;
        var errors = new LineLog(10_000);
        process.OutputDataReceived += (_, e) => { if (e.Data != null) onLine?.Invoke(e.Data); };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            errors.Append(e.Data);
            onErrorLine?.Invoke(e.Data);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try
        {
            if (stdin != null) process.StandardInput.BaseStream.Write(stdin);
            process.StandardInput.Close();
        }
        catch (IOException) { }

        bool cancelled = false;
        while (!process.WaitForExit(100))
        {
            if (!isCancelled()) continue;
            cancelled = true;
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            break;
        }
        process.WaitForExit(5000);
        if (cancelled) throw new OperationCanceledException();
        return new CommandResult(process.ExitCode, [], string.Join("\n", errors.All));
    }

    /// <summary>Как <see cref="Run"/>, но ненулевой код завершения считается ошибкой.</summary>
    public static CommandResult Check(string tool, IEnumerable<string> arguments, byte[]? stdin = null, TimeSpan? timeout = null,
                                      string? currentDirectory = null)
    {
        var result = Run(tool, arguments, stdin, timeout, currentDirectory);
        if (!result.Succeeded) throw new RunnerException(RunnerErrorKind.Failed, tool, result.Status, result.Stderr.Trim());
        return result;
    }

    /// <summary>Сценарий PowerShell без профиля. Вывод — в UTF-8: иначе русские сообщения системы
    /// пришли бы в кодировке консоли (866) и превратились бы в кракозябры.</summary>
    public static CommandResult PowerShell(string script, byte[]? stdin = null, TimeSpan? timeout = null)
    {
        var full = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference='SilentlyContinue';\n" + script;
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(full));
        return Run("powershell", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
                   stdin ?? [], timeout);
    }
}

/// <summary>Строки, которые собираются из фонового потока.</summary>
public sealed class LineLog(int limit = 200)
{
    readonly Lock gate = new();
    readonly List<string> lines = [];

    public void Append(string line)
    {
        lock (gate) { if (lines.Count < limit) lines.Add(line); }
    }

    public List<string> All
    {
        get { lock (gate) return [.. lines]; }
    }
}
