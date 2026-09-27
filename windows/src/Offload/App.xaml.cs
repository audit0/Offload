using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Offload.Core;

namespace Offload;

public partial class App : Application
{
    public static readonly string RepositoryUrl = "https://github.com/audit0/Offload";

    public static AppModel Model { get; private set; } = null!;
    static ElevatedVault? elevated;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Второй процесс OffLoadAI с правами администратора: только операции сейфа, без окон.
        if (e.Args.Length == 3 && e.Args[0] == "--vault-helper" && int.TryParse(e.Args[2], out var parent))
        {
            int code = VaultHelper.Serve(e.Args[1], parent);
            Shutdown(code);
            return;
        }
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.DefaultThreadCurrentUICulture = new CultureInfo("ru-RU");
        base.OnStartup(e);
        var snapshots = Demo.IsOn ? Environment.GetEnvironmentVariable("OFFLOAD_SNAPSHOT_DIR") : null;
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            // В режиме снимков окна с ошибкой некому закрыть — пишем её рядом со снимками и выходим.
            if (snapshots is { Length: > 0 })
            {
                try { File.AppendAllText(Path.Combine(snapshots, "error.txt"), args.Exception + "\n"); } catch (IOException) { }
                Shutdown(1);
                return;
            }
            MessageBox.Show(args.Exception.Message, "OffLoadAI", MessageBoxButton.OK, MessageBoxImage.Warning);
        };
        // Сейф: если OffLoadAI уже запущен от имени администратора, операции идут прямо здесь;
        // иначе — через второй процесс, который Windows запустит после запроса UAC.
        if (VaultOps.IsElevated) SecretsVault.Backend = new VaultOps();
        else SecretsVault.Backend = elevated = new ElevatedVault();

        try
        {
            Model = new AppModel();
        }
        catch (Exception error) when (snapshots is { Length: > 0 })
        {
            File.AppendAllText(Path.Combine(snapshots, "error.txt"), error + "\n");
            Shutdown(1);
            return;
        }
        MainWindow window;
        try { window = new MainWindow(Model); }
        catch (Exception error) when (snapshots is { Length: > 0 })
        {
            File.AppendAllText(Path.Combine(snapshots, "error.txt"), error + "\n");
            Shutdown(1);
            return;
        }
        MainWindow = window;
        window.Show();
        // Снимки — только в демонстрационном режиме. Иначе любая программа под этой учётной записью запустила бы
        // OffLoadAI и получила бы картинки с именами и размерами папок, записанные в любую папку.
        if (snapshots is { Length: > 0 } directory)
            Dispatcher.BeginInvoke(async () =>
            {
                try { await Snapshots.Run(directory, window, Model); }
                catch (Exception error)
                {
                    File.AppendAllText(Path.Combine(directory, "error.txt"), error + "\n");
                    Shutdown(1);
                }
            }, DispatcherPriority.ApplicationIdle);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        elevated?.Dispose();
        (SecretsVault.Backend as IDisposable)?.Dispose();
        base.OnExit(e);
    }
}
