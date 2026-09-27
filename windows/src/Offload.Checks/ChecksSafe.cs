using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using Offload.Core;
using static Offload.Checks.Harness;

namespace Offload.Checks;

// Проверки сейфа: пароль, настоящий зашифрованный образ, заголовок, место, закрытие
// и перенос открытых архивов внутрь. Пароли — только напрямую в BitLocker: ни одна проверка
// не должна вызвать системное окно с запросом пароля.
static partial class All
{
    static bool IsVault(Exception ex, VaultErrorKind kind) => ex is VaultException v && v.Kind == kind;

    static void ChecksSafe()
    {
        Section("Сейф: оценка пароля", () =>
        {
            foreach (var weak in new[] { "short", "Qwerty123!", "password12345678", "aaaaaaaaaaaaaaaaaaaa", "12345678901234567890", "йцукенйцукен",
                                         "Summer2024!!", "P@ssw0rd2024", "aCaCaCaCaCaC", "αγαγαγαγαγαγ", "Qwerty123!Qwerty", "Москва2024!!",
                                         "P@ssw0rd2024Summer!" })
                Check(!PasswordStrength.Evaluate(weak).IsAcceptable, $"слабый пароль «{weak}» не принимается (≈{(int)PasswordStrength.Evaluate(weak).Bits} бит)");
            foreach (var strong in new[] { "correct horse battery staple", "лось ест сено у реки в пять утра", "t7#Kp9!vQ2@xZ4&m" })
                Check(PasswordStrength.Evaluate(strong).IsAcceptable, $"стойкий пароль «{strong}» принимается (≈{(int)PasswordStrength.Evaluate(strong).Bits} бит)");
            Check(PasswordStrength.Evaluate("лось ест сено у реки в пять утра").Level >= PasswordLevel.Good, "фраза из случайных слов оценивается как надёжная");
            Check(PasswordStrength.Evaluate("").Bits == 0, "пустой пароль — ноль бит");
            Check(!PasswordStrength.Evaluate("лось ест сено у реки\0в пять утра").IsAcceptable, "пароль с нулевым байтом не принимается");
            Check(!PasswordStrength.Evaluate(new string('ж', 20) + string.Concat(Enumerable.Repeat("лось ест сено ", 30))).IsAcceptable,
                  "пароль длиннее 256 символов BitLocker не примет — и оценка его не принимает");
            Check(PasswordStrength.Evaluate("password-and-more-words").Advice.Any(a => a.Contains("password")),
                  "словарное слово названо в совете, а не просто снижает оценку");
        });

        Section("Сейф: подделки без BitLocker", () =>
        {
            var folder = Path.Combine(Scratch, "fakes");
            Directory.CreateDirectory(folder);
            // Файл с расширением .vhdx, но не образ; и образ с подписью «-FVE-FS-» в начале файла.
            File.WriteAllText(Path.Combine(folder, "Пустышка.vhdx"), "-FVE-FS- не образ");
            var fake = new SecretsVault(Path.Combine(folder, "Пустышка.vhdx"));
            Check(!fake.IsEncrypted, "файл с подписью BitLocker, но не образ, не выдаётся за сейф");
            ExpectError("такой файл не открывается как сейф", () => fake.Attach("any-password-12345"),
                        ex => IsVault(ex, VaultErrorKind.NotEncrypted));
            Check(SecretsVault.Candidates(folder).Count == 0, "подделка не выбирается как сейф диска");
            Check(BitLockerHeader.Info(Path.Combine(folder, "Пустышка.vhdx")) == null, "не-VHDX не разбирается как образ");
        });

        if (Env("OFFLOAD_SKIP_INTEGRATION") || Env("OFFLOAD_SKIP_VAULT") || !VaultOps.IsElevated)
        {
            Console.WriteLine("▸ Сейф на настоящих образах — пропущено (нужны права администратора и BitLocker)");
            return;
        }
        var ops = new VaultOps();
        SecretsVault.Backend = ops;
        try
        {
            SafeIntegration(ops);
        }
        finally
        {
            ops.DetachAll();
        }
    }

    static void SafeIntegration(VaultOps ops)
    {
        Section("Сейф: создание, занятость, место, заголовок, пароль", () =>
        {
            var folder = Path.Combine(Scratch, "safe-ops");
            Directory.CreateDirectory(folder);
            var image = Path.Combine(folder, "Сейф проверки.vhdx");
            var vault = new SecretsVault(image);
            const string first = "первый пароль сейфа для проверки 2026";
            const string second = "второй пароль сейфа тоже длинный 2026";
            ExpectError("слабым паролем сейф не создаётся", () => vault.Create("Qwerty123!", 256L << 20, "OffloadCheckOps"),
                        ex => IsVault(ex, VaultErrorKind.WeakPassword));
            vault.Create(first, 8L << 30, "OffloadCheckOps");
            Check((vault.SizeLimit ?? 0) >= 7L << 30, $"предел образа — сколько просили: {vault.SizeLimit}");
            Check(vault.AllocatedBytes < 256L << 20, $"образ разрежённый: на диске занимает {vault.AllocatedBytes} байт, а не 8 ГБ");
            Console.WriteLine($"  · пустой сейф с пределом 8 ГБ занимает {Format.Bytes(vault.AllocatedBytes)}");
            var info = BitLockerHeader.Info(image);
            Check(info is { Encrypted: true, PassphraseCount: 1, Uuid: not null, HasClearKey: false },
                  $"без пароля и без прав видно: зашифрован, один пароль, есть GUID — {info}");
            Check(vault.IsEncrypted, "настоящий сейф признан зашифрованным");

            ExpectError("неверный пароль не открывает сейф", () => vault.Attach("совсем не тот пароль 2026 года"),
                        ex => IsVault(ex, VaultErrorKind.WrongPassword));
            Check(vault.GetStatus() is { IsAttached: false }, "после неверного пароля образ отключён");
            var mount = vault.Attach(first);
            Check(Volumes.Info(mount)?.FsType == "ntfs", $"внутри сейфа NTFS: {Volumes.Info(mount)?.FsType}");
            var opened = vault.GetStatus();
            Check(opened.IsEncrypted && opened.IsAttached && Paths.Same(opened.MountPoint, mount),
                  $"открытый сейф признан зашифрованным и открытым: {opened}");
            Check(BitLockerShell.Protection(mount) is { IsEncrypted: true, IsLocked: false }, "Проводник видит сейф зашифрованным и открытым");
            Check(SecretsVault.Candidates(folder).Any(c => Paths.Same(c, image)), "открытый сейф остаётся среди зашифрованных образов диска");
            Check(SecretsVault.IsEncryptedImage(image), "открытый образ и в разборе опознаётся как зашифрованный");
            Check(Paths.Same(vault.Attach(first), mount), "повторное открытие открытого сейфа отдаёт тот же том, второй раз не подключая");
            ExpectError("копия заголовка с открытого сейфа не снимается", () => vault.BackupHeader(folder),
                        ex => IsVault(ex, VaultErrorKind.Busy));
            var root = new DirectoryInfo(mount).GetAccessControl();
            var identities = root.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Select(r => r.IdentityReference.Value).ToHashSet();
            Check(root.AreAccessRulesProtected && !identities.Contains(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null).Value)
                  && !identities.Contains(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null).Value),
                  $"корень сейфа закрыт от других пользователей: {string.Join(", ", identities)}");
            Check((File.GetAttributes(mount) & FileAttributes.NotContentIndexed) != 0, "индексатор Windows внутрь сейфа не заходит");

            var tinyHost = new VolumeInfo(folder, "Почти полный диск", "exfat", 10L << 30, Volumes.SafeHostReserve + (5L << 20), 4096, false, false);
            var clamped = Volumes.Safe(mount, tinyHost);
            Check(clamped?.IsEncryptedImage == true, "том сейфа помечен как зашифрованный");
            Check((clamped?.AvailableBytes ?? long.MaxValue) <= 5L << 20, $"свободное в сейфе ограничено местом на самом диске: {clamped?.AvailableBytes}");

            // Занятость: пока в сейфе открыт файл, обычное закрытие отказывает, а не обрывает чужую работу.
            var busyFile = Path.Combine(mount, "открыт.txt");
            File.WriteAllText(busyFile, "держу открытым");
            using (var handle = new FileStream(busyFile, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                ExpectError("сейф с открытым файлом без force не закрывается", () => SecretsVault.Detach(mount, attempts: 2),
                            ex => IsVault(ex, VaultErrorKind.Busy));
            }
            SecretsVault.Detach(mount);
            Check(vault.CurrentMountPoint() == null, "после закрытия файла сейф закрылся");
            var closed = vault.GetStatus();
            Check(closed is { Exists: true, IsEncrypted: true, IsAttached: false, MountPoint: null } && closed.Info?.PassphraseCount == 1,
                  $"закрытый сейф снова читается из файла: {closed}");
            Check(Try(() => SecretsVault.Detach(mount)), "закрыть уже закрытый сейф — не ошибка");

            // Сжатие: удалённое внутри сейфа место само на диск не возвращается, а после сжатия — возвращается.
            var small = new SecretsVault(Path.Combine(folder, "Маленький.vhdx"));
            small.Create(first, 1L << 30, "OffloadCheckSmall");
            mount = small.Attach(first);
            var big = Path.Combine(mount, "большой.bin");
            File.WriteAllBytes(big, RandomNumberGenerator.GetBytes(200 << 20));
            SecretsVault.Detach(mount);
            long filled = small.AllocatedBytes;
            mount = small.Attach(first);
            ExpectError("открытый сейф не сжимается", () => small.Compact(first), ex => IsVault(ex, VaultErrorKind.Busy));
            File.Delete(big);
            SecretsVault.Detach(mount);
            Check(small.AllocatedBytes > filled - (32L << 20), $"удалённое внутри сейфа место само на диск не возвращается: {small.AllocatedBytes}");
            ExpectError("сжатие чужим паролем не идёт", () => small.Compact(second), ex => IsVault(ex, VaultErrorKind.WrongPassword));
            File.WriteAllText(Path.Combine(Scratch, "keep.txt"), "");
            mount = small.Attach(first);
            File.WriteAllText(Path.Combine(mount, "остаётся.txt"), "переживёт сжатие");
            Directory.CreateDirectory(Path.Combine(mount, "папка", "вложенная"));
            File.WriteAllText(Path.Combine(mount, "папка", "вложенная", "файл.txt"), "тоже");
            SecretsVault.Detach(mount);
            var note = small.Compact(first);
            Console.WriteLine($"  · сжатие: было {filled}, стало {small.AllocatedBytes}");
            Check(small.AllocatedBytes < filled - (100L << 20), $"после сжатия место вернулось: было {filled}, стало {small.AllocatedBytes}");
            Check(note.Contains("заголовка"), "после сжатия сказано, что старые копии заголовка не подходят");
            Check(small.IsEncrypted && BitLockerHeader.Info(small.ImagePath)?.PassphraseCount == 1, "сжатый сейф зашифрован и открывается паролем");
            mount = small.Attach(first);
            Check(File.ReadAllText(Path.Combine(mount, "остаётся.txt")) == "переживёт сжатие"
                  && File.ReadAllText(Path.Combine(mount, "папка", "вложенная", "файл.txt")) == "тоже", "содержимое сейфа после сжатия на месте");
            Check(!Directory.EnumerateFiles(folder, "*.offload-*").Any(), "рядом с сейфом не осталось временных образов");
            SecretsVault.Detach(mount);

            // Резервная копия заголовка.
            var backups = Path.Combine(Scratch, "header-backups");
            Directory.CreateDirectory(backups);
            var backup = vault.BackupHeader(backups);
            var acl = new FileInfo(backup).GetAccessControl();
            Check(acl.AreAccessRulesProtected && acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Count == 1,
                  "копия заголовка доступна только владельцу");
            ExpectError("вторая копия в ту же папку первую не затирает", () => vault.BackupHeader(backups),
                        ex => IsVault(ex, VaultErrorKind.AlreadyExists));

            var (layout, original) = BitLockerHeader.Snapshot(image);
            var zeros = original.Select(b => new byte[b.Length]).ToArray();
            BitLockerHeader.Write(image, layout.PartitionOffset, layout.BlockOffsets, zeros);
            byte[][] Current() => BitLockerHeader.ReadRaw(image, layout.PartitionOffset, layout.BlockOffsets);
            Check(!vault.IsEncrypted, "с испорченными метаданными сейф не считается зашифрованным");
            ExpectError("с испорченным заголовком сейф не открывается даже верным паролем", () => vault.Attach(first));
            ExpectError("чужой пароль к копии заголовка не подходит", () => vault.RestoreHeader(backup, second),
                        ex => IsVault(ex, VaultErrorKind.HeaderRejected));
            Check(Current().All(b => b.All(x => x == 0)), "после неудачи прежние метаданные остались как были");
            vault.RestoreHeader(backup, first);
            Check(Current().Zip(original).All(p => p.First.SequenceEqual(p.Second)), "заголовок восстановлен из копии байт в байт");
            Check(!File.Exists(vault.PreviousHeaderPath), "отложенные метаданные рядом с сейфом не оставлены");
            mount = vault.Attach(first);
            SecretsVault.Detach(mount);

            // Смена пароля и та самая оговорка VeraCrypt: старая копия заголовка открывается старым паролем.
            ExpectError("неверный текущий пароль пароль не меняет", () => vault.ChangePassword("совсем не тот пароль 2026 года", second),
                        ex => IsVault(ex, VaultErrorKind.WrongPassword));
            ExpectError("слабый новый пароль не принимается", () => vault.ChangePassword(first, "short"),
                        ex => IsVault(ex, VaultErrorKind.WeakPassword));
            vault.ChangePassword(first, second);
            Check(BitLockerHeader.Info(image) is { PassphraseCount: 1, HasClearKey: false } after && after.OpensWithPassword,
                  "после смены у сейфа ровно один пароль и нет открытого ключа");
            ExpectError("после смены старый пароль не открывает", () => vault.Attach(first), ex => IsVault(ex, VaultErrorKind.WrongPassword));
            mount = vault.Attach(second);
            Check(Directory.Exists(mount), "новый пароль открывает");
            SecretsVault.Detach(mount);
            vault.RestoreHeader(backup, first);
            mount = vault.Attach(first);
            Check(Directory.Exists(mount), "старая копия заголовка возвращает старый пароль — об этом и предупреждает OffLoadAI");
            SecretsVault.Detach(mount);

            // Копия заголовка от другого сейфа не принимается.
            var other = new SecretsVault(Path.Combine(folder, "Другой.vhdx"));
            other.Create(second, 256L << 20, "OffloadCheckOther");
            var otherBackup = other.BackupHeader(backups);
            ExpectError("копия заголовка другого сейфа отклоняется", () => vault.RestoreHeader(otherBackup, second),
                        ex => IsVault(ex, VaultErrorKind.HeaderRejected));
        });

        Section("Сейф: увеличение предела", () =>
        {
            var folder = Path.Combine(Scratch, "safe-grow");
            Directory.CreateDirectory(folder);
            const string password = "пароль для роста сейфа 2026 года";
            var vault = new SecretsVault(Path.Combine(folder, "Растущий.vhdx"));
            vault.Create(password, 512L << 20, "OffloadCheckGrow");
            var mount = vault.Attach(password);
            long before = new DriveInfo(mount).TotalSize;
            File.WriteAllText(Path.Combine(mount, "данные.txt"), "должно пережить рост");
            ExpectError("открытый сейф не растягивается", () => vault.Grow(2L << 30, password), ex => IsVault(ex, VaultErrorKind.Busy));
            SecretsVault.Detach(mount);
            ExpectError("уменьшить нельзя", () => vault.Grow(100L << 20, password), ex => IsVault(ex, VaultErrorKind.GrowFailed));
            ExpectError("чужим паролем не растягивается", () => vault.Grow(2L << 30, "совсем не тот пароль 2026 года"));
            vault.Grow(2L << 30, password);
            Check((vault.SizeLimit ?? 0) >= 2L << 30, $"предел образа вырос: {vault.SizeLimit}");
            Check(vault.AllocatedBytes < 512L << 20, $"образ остался разрежённым: {vault.AllocatedBytes} байт");
            Check(vault.CurrentMountPoint() == null, "после роста сейф закрыт, как и был");
            mount = vault.Attach(password);
            long after = new DriveInfo(mount).TotalSize;
            Check(after > 1800L << 20 && after > before * 3, $"файловая система внутри заняла новое место: было {before}, стало {after}");
            Check(File.ReadAllText(Path.Combine(mount, "данные.txt")) == "должно пережить рост", "содержимое сейфа после роста на месте");
            SecretsVault.Detach(mount);
            vault.Grow(2L << 30, password);
            Check(vault.IsEncrypted, "повтор с тем же пределом проходит, сейф по-прежнему зашифрован");
        });

        Section("Сейф: зашифровать перенесённое", () =>
        {
            using var hostDisk = TestDisk.Create("safe-host", "exFAT", "OFFSAFEHOST", 3072);
            var host = hostDisk.Info;
            const string password = "пароль сейфа на пробном диске 2026";
            var vault = new SecretsVault(Path.Combine(host.MountPoint, SecretsVault.SafeImageName));
            vault.Create(password, 1L << 30, "OffloadCheckSafe");
            Check(Paths.Name(new SecretsVault(host).ImagePath) == SecretsVault.SafeImageName, "свой сейф на диске находится первым");
            var safeMount = vault.Attach(password);
            try
            {
                var safe = Volumes.Safe(safeMount, host) ?? throw new IOException("сейф не читается");
                var rules = new SafetyRules(Path.Combine(Scratch, "home-safe"), publicFolder: Path.Combine(Scratch, "public-safe"));
                var mover = new SafeMover(rules);
                var source = Path.Combine(rules.Home, "Documents", "Сканы паспорта");
                Write("очень личное", Path.Combine(source, "страница 1.txt"));
                Write("ещё личное", Path.Combine(source, "вложено", "страница 2.txt"));
                Write("только чтение", Path.Combine(source, "readonly.txt"));
                File.SetAttributes(Path.Combine(source, "readonly.txt"), FileAttributes.ReadOnly);

                var direct = Path.Combine(rules.Home, "Documents", "Сразу в сейф");
                Write("сразу", Path.Combine(direct, "a.txt"));
                var directRecord = mover.Execute(mover.Plan(direct, safe), deleteOriginal: true, acceptCautions: true);
                Check(directRecord.IsEncrypted && Paths.IsInside(directRecord.ArchivedPath, safeMount), "перенос в сейф ложится в сейф и помечен зашифрованным");

                var open = mover.Execute(mover.Plan(source, host), deleteOriginal: true, acceptCautions: true);
                Check(!open.IsEncrypted, "перенос на открытую часть диска помечен как незашифрованный");
                var moved = mover.Relocate(open, safe);
                Check(moved.IsEncrypted && Paths.IsInside(moved.ArchivedPath, safeMount), "архив переехал в сейф");
                Check(moved.Id == open.Id, "это та же запись журнала, а не новая");
                Check(!Directory.Exists(open.ArchivedPath), "открытая копия удалена");
                Check(!File.Exists(open.ArchivedPath + ".sha256"), "список сумм рядом с открытой копией тоже убран");
                Check(File.Exists(moved.ArchivedPath + ".sha256"), "список сумм переехал вместе с архивом");
                Check(Journal.Records(host).All(r => r.Id != open.Id), "в журнале открытой части записи больше нет");
                Check(Journal.Records(safe).Any(r => r.Id == open.Id && r.IsEncrypted), "в журнале внутри сейфа запись есть");
                Check(Paths.Same(Journal.LocalRecords().First(r => r.Id == open.Id).ArchivedPath, moved.ArchivedPath), "локальный журнал указывает на сейф");
                ExpectError("архив, уже лежащий в сейфе, второй раз не переносится", () => mover.Relocate(moved, safe));

                var outcome = mover.Restore(moved, deleteArchive: true);
                Check(File.ReadAllText(Path.Combine(source, "вложено", "страница 2.txt")) == "ещё личное", "данные вернулись из сейфа");
                Check((File.GetAttributes(Path.Combine(source, "readonly.txt")) & FileAttributes.ReadOnly) != 0,
                      "атрибут «только чтение» вернулся из списка, приехавшего в сейф");
                Check(!outcome.NeedsAttention, $"возврат из сейфа прошёл без поводов для тревоги: {string.Join(" ", outcome.Notes)}");
            }
            finally
            {
                SecretsVault.DetachIgnoringErrors(safeMount);
            }
        });
    }

    static bool Try(Action action)
    {
        try { action(); return true; }
        catch (Exception) { return false; }
    }
}
