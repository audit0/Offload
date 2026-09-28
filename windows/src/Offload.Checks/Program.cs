using System.Text;
using Offload.Core;
using static Offload.Checks.Harness;

// Проверки ядра OffLoadAI для Windows.
// Запуск: dotnet run --project src/Offload.Checks
//   OFFLOAD_CHECKS_ONLY=rules,copy — только эти разделы (список — в All.cs)
//   OFFLOAD_SKIP_INTEGRATION=1 — без проверок на настоящих образах дисков (нужны права администратора)
//   OFFLOAD_SKIP_VAULT=1       — без проверок сейфа (нужен BitLocker: Windows Pro, Enterprise или Education)
//   OFFLOAD_SKIP_DOCKER=1      — без проверок с Docker

Console.OutputEncoding = Encoding.UTF8;
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

// Программа проверок служит и подопытной внешней программой для проверок Runner: печатает аргументы,
// отдаёт stdin, спит, завершается с кодом или печатает переменную окружения.
if (args.Length >= 1 && args[0] == "--echo-args")
{
    using var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
    foreach (var argument in args.Skip(1))
    {
        output.Write(argument + "\n");
        output.Flush();
    }
    return 0;
}
if (args.Length == 1 && args[0] == "--cat")
{
    Console.OpenStandardInput().CopyTo(Console.OpenStandardOutput());
    return 0;
}
if (args.Length == 2 && args[0] == "--sleep")
{
    Thread.Sleep(TimeSpan.FromSeconds(int.Parse(args[1])));
    return 0;
}
if (args.Length == 2 && args[0] == "--exit") return int.Parse(args[1]);
if (args.Length == 2 && args[0] == "--env")
{
    Console.Write(Environment.GetEnvironmentVariable(args[1]) ?? "");
    return 0;
}

Directory.CreateDirectory(Scratch);
Journal.LocalOverride = Path.Combine(Scratch, "history.json");

Offload.Checks.All.Run();

try { FileSystem.TryDeleteTree(Scratch); } catch { }
Console.WriteLine($"\nИтог: пройдено {Passed}, не пройдено {Failed}");
return Failed == 0 ? 0 : 1;
