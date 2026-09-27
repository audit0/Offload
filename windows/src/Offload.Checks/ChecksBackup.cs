using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Бэкап: что считается секретом, что не попадает в открытую копию, и что бывает, если на диске
// бэкапа подложены ссылки. Плюс то, что складывается в сейф (Fill) — в обычную папку, без BitLocker.
static partial class All
{
    static void ChecksBackup()
    {
        Section("Бэкап: секреты", () =>
        {
            Check(BackupEngine.IsSecret(".env") && BackupEngine.IsSecret(".env.production"), ".env считается секретом");
            Check(!BackupEngine.IsSecret(".env.example"), ".env.example — не секрет");
            Check(BackupEngine.IsSecret("id_ed25519") && BackupEngine.IsSecret("server.KEY") && BackupEngine.IsSecret("vault.kdbx"), "ключи и базы паролей — секреты");
            Check(!BackupEngine.IsSecret("id_ed25519.pub") && !BackupEngine.IsSecret("README.md"), "публичный ключ и обычные файлы — не секреты");
            Check(BackupEngine.IsSecret(".envrc") && BackupEngine.IsSecret("key.p8") && BackupEngine.IsSecret("credentials"), ".envrc, ключ .p8 и файл credentials — секреты");
            Check(BackupEngine.IsSecret("putty.ppk") && BackupEngine.IsSecret("cert.pfx") && BackupEngine.IsSecret("ConsoleHost_history.txt"),
                  "ключ PuTTY, сертификат .pfx и история PowerShell — секреты");
            Check(BackupEngine.IsSecretFolder(".ssh") && BackupEngine.IsSecretFolder(".gnupg") && BackupEngine.IsSecretFolder(".aws")
                  && BackupEngine.IsSecretFolder(".AWS"), "каталоги с ключами распознаются целиком, без учёта регистра");
            foreach (var name in new[] { "prod.env", ".env-local", ".env_local", "terraform.tfstate", "prod.tfvars", "credentials.json",
                                         "service-account.json", "client_secret_123.json", "id_rsa.bak", "id_ed25519.old", ".vault-token",
                                         ".htpasswd", ".zsh_history", "auth.json", "_netrc", ".git-credentials", "ID_RSA" })
                Check(BackupEngine.IsSecret(name), $"«{name}» — секрет, в открытый бэкап не идёт");
            foreach (var name in new[] { "id_ed25519.pub", ".env.example", "package.json", "README.md", "venv", ".env.sample" })
                Check(!BackupEngine.IsSecret(name), $"«{name}» — не секрет");

            var keyProbe = Room("key-probe");
            Write("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n", Path.Combine(keyProbe, "deploy_key"));
            Write("just text\n", Path.Combine(keyProbe, "NOTES"));
            Check(BackupEngine.IsSecretPath("deploy_key", keyProbe), "ключ без расширения узнаётся по первым байтам");
            Check(!BackupEngine.IsSecretPath("NOTES", keyProbe), "обычный файл без расширения секретом не считается");
            Check(BackupEngine.IsSecretPath(@".ssh\config", keyProbe), "файл внутри .ssh — секрет по каталогу");

            var project = Room("audit-project");
            Write("[remote \"origin\"]\n\turl = https://me:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/me/app.git\n", Path.Combine(project, @".git\config"));
            Write("{\"type\": \"service_account\", \"private_key\": \"-----BEGIN\"}", Path.Combine(project, "gcp.json"));
            Write("token: gho_abcdef\n", Path.Combine(project, @".config\gh\hosts.yml"));
            Write("-----BEGIN OPENSSH PRIVATE KEY-----\n", Path.Combine(project, ".deploy_key"));
            Write("$env:OPENAI_KEY = 'sk-proj-abcdef'\n", Path.Combine(project, "setup.ps1"));
            Write("{\"name\": \"app\"}", Path.Combine(project, "package.json"));
            foreach (var relative in new[] { @".git\config", "gcp.json", @".config\gh\hosts.yml", ".deploy_key", "setup.ps1" })
                Check(BackupEngine.IsSecretPath(relative, project), $"«{relative}» узнаётся как секрет по месту или содержимому");
            Check(!BackupEngine.IsSecretPath("package.json", project), "обычный package.json — не секрет");
            if (CanSymlink)
            {
                // Содержимое проверяется только у обычного файла: ссылка на чужой файл не читается.
                FileLink(Path.Combine(project, "linked.json"), Path.Combine(project, "gcp.json"));
                Check(!BackupEngine.IsSecretPath("linked.json", project), "ссылка на файл с ключом не читается ради проверки содержимого");
            }
        });

        Section("Бэкап: копирование", () =>
        {
            var project = Room("proj");
            Write("code", Path.Combine(project, "main.cs"));
            Write("TOKEN=1", Path.Combine(project, ".env"));
            Write("dep", Path.Combine(project, @"node_modules\lib\index.js"));
            Write("export AWS_SECRET_ACCESS_KEY=1", Path.Combine(project, ".envrc"));
            Write("key", Path.Combine(project, @".ssh\id_work"));
            Write("obj", Path.Combine(project, @".vs\state.bin"));
            Write("-----BEGIN OPENSSH PRIVATE KEY-----\n", Path.Combine(project, ".deploy_key"));
            var backup = Path.Combine(Scratch, "backup");
            var first = BackupEngine.Run([project], backup);
            Check(Exists(Path.Combine(backup, @"proj\main.cs")), "код попал в бэкап");
            Check(!Exists(Path.Combine(backup, @"proj\.env")), ".env не попал в открытый бэкап");
            Check(!Exists(Path.Combine(backup, @"proj\.envrc")), ".envrc не попал в открытый бэкап");
            Check(!Exists(Path.Combine(backup, @"proj\.ssh")), "папка .ssh внутри проекта не попала в открытый бэкап");
            Check(!Exists(Path.Combine(backup, @"proj\.deploy_key")), "скрытый файл с приватным ключом не попал в открытый бэкап");
            Check(first.SecretsSkipped.Where(s => s != @"proj\.deploy_key").ToHashSet().SetEquals([@"proj\.env", @"proj\.envrc", @"proj\.ssh\"]),
                  $"пропущенные секреты отмечены в отчёте ({string.Join(", ", first.SecretsSkipped)})");
            Check(!Exists(Path.Combine(backup, @"proj\node_modules")) && !Exists(Path.Combine(backup, @"proj\.vs")), "node_modules и .vs исключены");
            var second = BackupEngine.Run([project], backup);
            Check(second.Copied == 0 && second.Unchanged >= 1, "повторный бэкап ничего не копирует заново");
            Write("code v2", Path.Combine(project, "main.cs"));
            Check(BackupEngine.Run([project], backup).Copied == 1, "изменённый файл копируется");
            Check(Read(Path.Combine(backup, @"proj\main.cs")) == "code v2", "в бэкапе — новая версия");
            File.Delete(Path.Combine(project, "main.cs"));
            BackupEngine.Run([project], backup);
            Check(Exists(Path.Combine(backup, @"proj\main.cs")), "удалённый на компьютере файл в бэкапе остаётся");
            // Файл «только для чтения» в бэкапе (так git держит свои объекты) обновляется, а не срывает бэкап.
            Write("ro v1", Path.Combine(project, "readonly.txt"));
            BackupEngine.Run([project], backup);
            Add(Path.Combine(backup, @"proj\readonly.txt"), FileAttributes.ReadOnly);
            File.WriteAllText(Path.Combine(project, "readonly.txt"), "ro version 2");
            var readOnly = BackupEngine.Run([project], backup);
            Check(readOnly.Problems.Count == 0 && Read(Path.Combine(backup, @"proj\readonly.txt")) == "ro version 2",
                  $"файл «только для чтения» в бэкапе обновился: {string.Join(" ", readOnly.Problems)}");

            ExpectError("бэкап внутрь копируемой папки запрещён", () => BackupEngine.Run([project], Path.Combine(project, "backup")),
                        ex => ex is BackupException);
            ExpectError("бэкап в саму копируемую папку запрещён", () => BackupEngine.Run([project], project), ex => ex is BackupException);

            // Папка бэкапа, путь к которой проходит через точку соединения, — не та папка, о которой думает человек.
            var elsewhere = Room("backup-elsewhere");
            var linked = Path.Combine(Scratch, "backup-junction");
            Junction(linked, elsewhere);
            ExpectError("бэкап через точку соединения отклоняется", () => BackupEngine.Run([project], Path.Combine(linked, "Offload Backup")),
                        ex => ex is BackupException && ex.Message.Contains("ссылку"));
            Check(Directory.GetFileSystemEntries(elsewhere).Length == 0, "за точкой соединения ничего не создано");

            // Внутри бэкапа подложена точка соединения на месте папки проекта: файлы по ней не уходят.
            var root = Path.Combine(Scratch, "backup-trap");
            var outside = Room("backup-outside");
            Junction(Path.Combine(root, @"proj\node"), outside);
            Write("x", Path.Combine(project, @"node\file.txt"));
            var trapped = BackupEngine.Run([project], root);
            Check(Directory.GetFileSystemEntries(outside).Length == 0, "через подложенную точку соединения ничего не записано");
            Check(trapped.Problems.Any(p => p.Contains("node")), $"о подложенной ссылке сказано в отчёте: {string.Join(" ", trapped.Problems)}");
        });

        Section("Сейф: что складывается (в обычную папку)", () =>
        {
            var home = Room("home-vault");
            bool keygen = Runner.Locate("ssh-keygen") != null;
            Directory.CreateDirectory(Path.Combine(home, ".ssh"));
            if (keygen)
                Runner.Check("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "offload-check", "-f", Path.Combine(home, @".ssh\id_check")],
                             timeout: TimeSpan.FromSeconds(30));
            else Write("-----BEGIN OPENSSH PRIVATE KEY-----\n", Path.Combine(home, @".ssh\id_check"));
            Write("[user]\n\tname = q\n", Path.Combine(home, ".gitconfig"));
            var app = Path.Combine(home, @"projects\app");
            Write("API_KEY=1", Path.Combine(app, ".env"));
            Write("KEY", Path.Combine(app, @"config\server.key"));
            Write("API_KEY=", Path.Combine(app, ".env.example"));
            Write("x", Path.Combine(app, @"node_modules\pkg\.env"));
            Write("export AWS_SECRET_ACCESS_KEY=1", Path.Combine(app, ".envrc"));
            Write("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n", Path.Combine(app, "deploy_key"));
            Write("$env:TOKEN = 'ghp_x'", Path.Combine(home, @"Documents\PowerShell\Microsoft.PowerShell_profile.ps1"));
            Write("kdbx", Path.Combine(home, @"Downloads\base.kdbx"));

            var mount = Room("vault-folder");
            Write("моя заметка", Path.Combine(mount, "КАК-ВОССТАНОВИТЬ.txt"));
            var projects = Path.Combine(home, "projects");
            var report = SecretsVault.Fill(mount, home, [projects]);
            Check(report.Problems.Count == 0, $"без ошибок: {string.Join(" | ", report.Problems.Take(2))}");
            Check(Exists(Path.Combine(mount, @"ssh\id_check")), "ключ SSH на месте");
            Check(Exists(Path.Combine(mount, @"dotfiles\.gitconfig")), "дотфайлы на месте");
            Check(Exists(Path.Combine(mount, @"project-secrets\app\.env")), ".env проекта на месте");
            Check(Exists(Path.Combine(mount, @"project-secrets\app\config\server.key")), "ключ из подпапки на месте");
            Check(!Exists(Path.Combine(mount, @"project-secrets\app\.env.example")), "шаблон .env.example не считается секретом");
            Check(!Exists(Path.Combine(mount, @"project-secrets\app\node_modules")), "node_modules пропущены");
            Check(Exists(Path.Combine(mount, @"project-secrets\app\.envrc")), ".envrc проекта попал в сейф");
            Check(Exists(Path.Combine(mount, @"project-secrets\app\deploy_key")), "ключ без расширения попал в сейф");
            Check(Exists(Path.Combine(mount, @"powershell\PowerShell\Microsoft.PowerShell_profile.ps1")), "профиль PowerShell попал в сейф");
            if (keygen) Check(report.UnprotectedKeys.SequenceEqual(["id_check"]), $"найден ключ без парольной фразы ({string.Join(", ", report.UnprotectedKeys)})");
            else Console.WriteLine("  (ssh-keygen не найден — проверка ключей без парольной фразы пропущена)");
            Check(Exists(Path.Combine(mount, @"keepass\base.kdbx")), "база KeePass из Загрузок на месте");
            Check(Read(Path.Combine(mount, "КАК-ВОССТАНОВИТЬ.txt")) == "моя заметка", "существующая заметка в сейфе не затёрта");

            var other = Path.Combine(home, "other");
            Write("OTHER=1", Path.Combine(other, @"app\.env"));
            var clash = SecretsVault.Fill(mount, home, [projects, other]);
            Check(clash.Problems.Any(p => p.Contains(@"app\.env")), "одинаковый путь из двух папок отмечен как проблема");
            Check(Read(Path.Combine(mount, @"project-secrets\app\.env")) == "API_KEY=1", "секрет первой папки не затёрт второй");
        });
    }
}
