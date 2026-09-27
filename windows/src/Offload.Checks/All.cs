namespace Offload.Checks;

static partial class All
{
    /// <summary>Разделы по коротким именам: OFFLOAD_CHECKS_ONLY=rules,copy выбирает только их.</summary>
    static readonly (string name, Action run)[] Sections =
    [
        ("rules", ChecksRules),
        ("copy", ChecksCopy),
        ("journal", ChecksJournal),
        ("space", ChecksSpace),
        ("backup", ChecksBackup),
        ("runner", ChecksRunner),
        ("format", ChecksFormat),
        ("memory", ChecksMemory),
        ("docker", ChecksDocker),
        ("cleanup", ChecksCleanup),
        ("duplicates", ChecksDuplicates),
        ("habits", ChecksHabits),
        ("store", ChecksStore),
        ("cloud", ChecksCloudRestore),
        ("trash", ChecksTrash),
        ("restore", ChecksRestore),
        ("harden", ChecksHarden),
        ("safe", ChecksSafe),
        ("license", ChecksLicense),
    ];

    public static void Run()
    {
        var only = Environment.GetEnvironmentVariable("OFFLOAD_CHECKS_ONLY");
        var wanted = string.IsNullOrEmpty(only) ? null : only.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (wanted?.FirstOrDefault(w => Sections.All(s => s.name != w)) is { } unknown)
            Console.WriteLine($"▸ Неизвестный раздел «{unknown}». Есть: {string.Join(", ", Sections.Select(s => s.name))}");
        try
        {
            foreach (var (name, run) in Sections)
                if (wanted == null || wanted.Contains(name)) run();
        }
        finally
        {
            DisposeDisks();
        }
    }
}
