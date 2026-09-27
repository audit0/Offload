using System.Text;
using Offload.Core;
using static Offload.Checks.Harness;

// Проверки ядра Offload для Windows.
// Запуск: dotnet run --project src/Offload.Checks
//   OFFLOAD_SKIP_INTEGRATION=1 — без проверок на настоящих образах дисков (нужны права администратора)
//   OFFLOAD_SKIP_VAULT=1       — без проверок сейфа (нужен BitLocker: Windows Pro, Enterprise или Education)
//   OFFLOAD_SKIP_DOCKER=1      — без проверок с Docker

Console.OutputEncoding = Encoding.UTF8;
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
if (args.Length == 2 && args[0] == "--probe-vhdx")
{
    Console.WriteLine(BitLockerHeader.Info(args[1]));
    return 0;
}
if (args.Length == 1 && args[0] == "--probe-attached")
{
    foreach (var volume in Offload.Core.Native.AllVolumeGuidPaths())
    {
        var bus = Offload.Core.Native.StorageBus(volume.TrimEnd('\\'));
        Console.WriteLine($"{volume} bus={bus} mounts={string.Join(",", Offload.Core.Native.VolumeMountPoints(volume))} backing={Offload.Core.VirtualDisks.BackingFile(volume)}");
    }
    foreach (var (k, v) in SecretsVault.AttachedImages()) Console.WriteLine($"attached: {k} → {v}");
    return 0;
}
if (args.Length == 2 && args[0] == "--probe-states")
{
    using (var disk = Vhdx.Open(args[1])!)
        Console.WriteLine($"states={string.Join(",", disk.BlockStates().Select(p => $"{p.Key}:{p.Value}"))} block={disk.BlockSize}");
    VirtualDisks.Compact(args[1]);
    using (var disk = Vhdx.Open(args[1])!)
        Console.WriteLine($"after compact: file={new FileInfo(args[1]).Length} states={string.Join(",", disk.BlockStates().Select(p => $"{p.Key}:{p.Value}"))}");
    return 0;
}
if (args.Length == 1 && args[0] == "--probe-compact")
{
    var ops = new VaultOps();
    SecretsVault.Backend = ops;
    var dir = Path.Combine(Path.GetTempPath(), "offload-compact-probe");
    FileSystem.TryDeleteTree(dir);
    Directory.CreateDirectory(dir);
    var image = Path.Combine(dir, "probe.vhdx");
    var vault = new SecretsVault(image);
    const string password = "пароль пробы сжатия 2026 года";
    vault.Create(password, 1L << 30, "Probe");
    void Stats(string label)
    {
        using var disk = Vhdx.Open(image)!;
        Console.WriteLine($"{label}: file={new FileInfo(image).Length} states={string.Join(",", disk.BlockStates().Select(p => $"{p.Key}:{p.Value}"))}");
    }
    Stats("created");
    var mount = vault.Attach(password);
    File.WriteAllBytes(Path.Combine(mount, "big.bin"), System.Security.Cryptography.RandomNumberGenerator.GetBytes(300 << 20));
    SecretsVault.Detach(mount);
    Stats("filled");
    mount = vault.Attach(password);
    File.Delete(Path.Combine(mount, "big.bin"));
    var volume = Native.VolumeGuidPath(mount)!;
    var defrag = Runner.Run("defrag", [mount.TrimEnd('\\'), "/L", "/U"], timeout: TimeSpan.FromMinutes(10));
    Console.WriteLine($"defrag {mount}: {defrag.Status}\n{System.Text.Encoding.GetEncoding(866).GetString(defrag.Stdout)}");
    SecretsVault.Detach(mount);
    Stats("trimmed");
    VirtualDisks.Compact(image);
    Stats("compacted");
    return 0;
}
Directory.CreateDirectory(Scratch);
Journal.LocalOverride = Path.Combine(Scratch, "history.json");

Offload.Checks.All.Run();

try { FileSystem.TryDeleteTree(Scratch); } catch { }
Console.WriteLine($"\nИтог: пройдено {Passed}, не пройдено {Failed}");
return Failed == 0 ? 0 : 1;
