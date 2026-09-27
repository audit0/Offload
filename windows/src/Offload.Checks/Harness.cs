using System.Runtime.CompilerServices;
using Offload.Core;

namespace Offload.Checks;

/// <summary>Свой минимальный раннер проверок, как у версии для Mac: без тестового фреймворка.</summary>
static class Harness
{
    public static int Passed;
    public static int Failed;
    public static readonly string Scratch = Path.Combine(Path.GetTempPath(), "offload-checks-" + Guid.NewGuid().ToString("N"));

    public static void Check(Func<bool> condition, string message, [CallerLineNumber] int line = 0)
    {
        try
        {
            if (condition()) Passed++;
            else
            {
                Failed++;
                Console.WriteLine($"  ✗ {message} [строка {line}]");
            }
        }
        catch (Exception ex)
        {
            Failed++;
            Console.WriteLine($"  ✗ {message}: {ex.GetType().Name}: {ex.Message} [строка {line}]");
        }
    }

    public static void Check(bool condition, string message, [CallerLineNumber] int line = 0) => Check(() => condition, message, line);

    public static void ExpectError(string message, Action body, Func<Exception, bool>? matching = null, [CallerLineNumber] int line = 0)
    {
        try
        {
            body();
            Failed++;
            Console.WriteLine($"  ✗ {message}: ошибки не было [строка {line}]");
        }
        catch (Exception ex)
        {
            if (matching == null || matching(ex)) Passed++;
            else
            {
                Failed++;
                Console.WriteLine($"  ✗ {message}: неожиданная ошибка {ex.GetType().Name}: {ex.Message} [строка {line}]");
            }
        }
    }

    public static void Section(string title, Action body)
    {
        Console.WriteLine("▸ " + title);
        try { body(); }
        catch (Exception ex)
        {
            Failed++;
            Console.WriteLine($"  ✗ раздел прерван: {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}");
        }
    }

    public static bool IsBlocked(Verdict verdict, string? containing = null) =>
        verdict.IsBlocked && (containing == null || verdict.Reason!.Contains(containing, StringComparison.Ordinal));

    public static void Write(string text, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    public static bool Env(string name) => Environment.GetEnvironmentVariable(name) == "1";
}
