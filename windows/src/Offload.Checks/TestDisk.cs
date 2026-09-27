using Microsoft.Win32.SafeHandles;
using Offload.Core;

namespace Offload.Checks;

/// <summary>Пробный диск для проверок: образ VHDX с нужной файловой системой и буквой. Как пробные
/// образы hdiutil у версии для Mac — перенос и возврат проверяются на настоящей exFAT и NTFS.</summary>
sealed class TestDisk : IDisposable
{
    public string Image { get; }
    public string Root { get; }
    readonly SafeFileHandle handle;

    TestDisk(string image, string root, SafeFileHandle handle)
    {
        Image = image;
        Root = root;
        this.handle = handle;
    }

    public static TestDisk Create(string name, string fileSystem, string label, long megabytes)
    {
        var image = Path.Combine(Harness.Scratch, name + ".vhdx");
        VirtualDisks.Create(image, megabytes << 20);
        var handle = VirtualDisks.Attach(image);
        int disk = VirtualDisks.DiskNumber(handle);
        var result = Runner.PowerShell($$"""
            Initialize-Disk -Number {{disk}} -PartitionStyle GPT | Out-Null
            $p = New-Partition -DiskNumber {{disk}} -UseMaximumSize
            Format-Volume -Partition $p -FileSystem {{fileSystem}} -NewFileSystemLabel '{{label}}' -Confirm:$false -Force | Out-Null
            $p | Add-PartitionAccessPath -AssignDriveLetter
            (Get-Partition -DiskNumber {{disk}} -PartitionNumber $p.PartitionNumber).DriveLetter
            """, timeout: TimeSpan.FromMinutes(5));
        var letter = result.Output.Trim().Split('\n').Last().Trim();
        if (!result.Succeeded || letter.Length != 1)
        {
            VirtualDisks.Detach(handle);
            handle.Dispose();
            throw new IOException("пробный диск не создан: " + result.Stderr + result.Output);
        }
        return new TestDisk(image, letter + @":\", handle);
    }

    public VolumeInfo Info => Volumes.Info(Root) ?? throw new IOException("пробный диск не читается");

    public void Dispose()
    {
        try { VirtualDisks.Detach(handle); } catch (IOException) { }
        handle.Dispose();
    }
}
