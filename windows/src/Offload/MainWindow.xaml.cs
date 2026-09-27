using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Строка боковой колонки: выбранная — на светлой подложке и жирным.</summary>
public sealed class SidebarItem(SidebarSection section) : Observable
{
    public SidebarSection Section { get; } = section;
    public string Title => Section.Title();
    public string Glyph => Section.Glyph();
    bool isSelected;
    public bool IsSelected { get => isSelected; set => Set(ref isSelected, value); }
    int badge;
    /// <summary>Сколько перенесённого лежит на дисках — видно, не заходя в раздел. Ноль не показывается.</summary>
    public int Badge { get => badge; set => Set(ref badge, value); }
}

public partial class MainWindow : Window
{
    readonly AppModel app;
    readonly List<SidebarItem> items = SidebarSections.All.Select(s => new SidebarItem(s)).ToList();
    readonly Dictionary<SidebarSection, FrameworkElement> pages = [];
    bool closing;

    public MainWindow(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        StatusPanel.App = app;
        ProRowHost.Content = new ProSidebarRow(app);
        app.Pro.Offered += ShowPro;
        // Пробный период считается днями: окно могло простоять открытым со вчера.
        Activated += (_, _) => app.Pro.Refresh();
        SidebarList.ItemsSource = items;
        app.PropertyChanged += App_PropertyChanged;
        app.History.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(HistoryModel.PendingCount)) UpdateBadges(); };
        app.Safe.PropertyChanged += Safe_PropertyChanged;
        Show(app.Section);
        UpdateBadges();
        app.History.Reload(app.HistoryVolumes);
        InputBindings.Add(new KeyBinding(new Command(() => app.Safe.Close(app), () => app.Safe.IsOpen), Key.L, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => app.Section = SidebarSection.Safe), Key.D0, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Command(() => Ui.Open(App.RepositoryUrl)), Key.F1, ModifierKeys.None));
        SourceInitialized += (_, _) => SetupWindow();
        Closing += Window_Closing;
    }

    void App_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppModel.Section):
                Show(app.Section);
                break;
            case nameof(AppModel.HistoryVolumes):
                // Журнал нужен не только разделу «Перенесённое»: «Обзор» и «Сейф» по нему видят, что лежит на диске открыто.
                app.History.Reload(app.HistoryVolumes);
                break;
        }
    }

    void Safe_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        // Закрыть сейф не дали открытые в нём файлы — откуда бы ни закрывали.
        if (e.PropertyName == nameof(SafeModel.CloseBlocked) && app.Safe.CloseBlocked)
        {
            app.Safe.CloseBlocked = false;
            bool force = Dialogs.Confirm(this, "Сейф не закрывается",
                "В нём открыты файлы в других программах. Закройте их и повторите — или закройте сейф принудительно: несохранённое в этих программах может пропасть.",
                "Закрыть принудительно", "Оставить открытым", Tone.Caution, Glyphs.Lock);
            if (force) app.Safe.Close(app, force: true);
        }
    }

    ProSheet? proSheet;

    /// <summary>Окно «Offload Pro» — одно: уже открыто — просто вперёд.</summary>
    void ShowPro(ProFeature? reason)
    {
        if (proSheet != null) { proSheet.Activate(); return; }
        proSheet = new ProSheet(app, reason) { Owner = this };
        proSheet.Closed += (_, _) => proSheet = null;
        proSheet.ShowDialog();
    }

    void UpdateBadges()
    {
        foreach (var item in items) item.Badge = item.Section == SidebarSection.History ? app.History.PendingCount : 0;
    }

    void Section_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SidebarItem item }) app.Section = item.Section;
    }

    void Show(SidebarSection section)
    {
        foreach (var item in items) item.IsSelected = item.Section == section;
        if (!pages.TryGetValue(section, out var page))
        {
            page = Pages.Create(section, app);
            pages[section] = page;
        }
        Page.Content = page;
    }

    void About_Click(object sender, RoutedEventArgs e) => Dialogs.About(this);

    // MARK: Окно: стекло Windows 11 и подключение дисков

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    [StructLayout(LayoutKind.Sequential)]
    struct Margins { public int Left, Right, Top, Bottom; }

    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_SYSTEMBACKDROP_TYPE = 38;
    const int WM_DEVICECHANGE = 0x0219, DBT_DEVICEARRIVAL = 0x8000, DBT_DEVICEREMOVECOMPLETE = 0x8004;

    /// <summary>Всё окно — стекло: рабочий стол размыто просвечивает сквозь Mica. Тема одна — светлая, при любой
    /// теме Windows. Где Mica нет (Windows 10) или идут снимки экрана, фон — ровная светлая заливка.</summary>
    void SetupWindow()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var source = HwndSource.FromHwnd(handle);
        source.AddHook(WindowProc);
        int light = 0;
        DwmSetWindowAttribute(handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref light, sizeof(int));
        bool snapshots = Environment.GetEnvironmentVariable("OFFLOAD_SNAPSHOT_DIR") is { Length: > 0 };
        if (Environment.OSVersion.Version.Build >= 22000 && !snapshots)
        {
            int mica = 2;
            if (DwmSetWindowAttribute(handle, DWMWA_SYSTEMBACKDROP_TYPE, ref mica, sizeof(int)) == 0)
            {
                var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
                DwmExtendFrameIntoClientArea(handle, ref margins);
                source.CompositionTarget.BackgroundColor = Colors.Transparent;
                Background = Brushes.Transparent;
                return;
            }
        }
        Background = new SolidColorBrush(Color.FromRgb(0xE9, 0xE9, 0xEE));
    }

    IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        // Подключили или отключили диск — в том числе сейф, открытый или закрытый в обход Offload.
        if (message == WM_DEVICECHANGE && (wParam == DBT_DEVICEARRIVAL || wParam == DBT_DEVICEREMOVECOMPLETE))
        {
            bool arrived = wParam == DBT_DEVICEARRIVAL;
            Dispatcher.BeginInvoke(() => app.VolumesChanged(arrived));
        }
        return IntPtr.Zero;
    }

    // MARK: Выход

    /// <summary>Пока идёт копирование, выход убил бы фоновую работу на полпути, и рядом с папкой осталась бы скрытая
    /// недокопия «.offload-partial-…» в полный размер. Поэтому сначала спрашиваем, потом отменяем по-человечески
    /// и ждём, пока уберётся мусор. Выходя, сейф закрываем всегда: оставить его открытым без программы,
    /// которая следит за сном, блокировкой и простоем, значило бы оставить ключ в памяти без присмотра.</summary>
    async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (closing) return;
        if (!app.IsBusy)
        {
            e.Cancel = !CloseSafeBeforeQuit();
            closing = !e.Cancel;
            return;
        }
        e.Cancel = true;
        bool quit = Dialogs.Confirm(this, "Сейчас идёт копирование",
            "Если выйти, копирование прервётся. Данные не пострадают: оригинал не удаляется, пока копия не сверена, а незаконченная копия будет убрана.",
            "Прервать и выйти", "Не выходить", Tone.Caution, Glyphs.Warning);
        if (!quit) return;
        app.CancelEverything();
        // Отмена проверяется между файлами, поэтому ждём настоящего конца работы, но не дольше полуминуты.
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (app.IsBusy && DateTime.UtcNow < deadline) await Task.Delay(200);
        if (!CloseSafeBeforeQuit()) return;
        closing = true;
        _ = Dispatcher.BeginInvoke(Close);
    }

    /// <summary>Сейф закрывается вместе с программой в любом случае: образ подключён, пока жив процесс,
    /// который за ним следит. Если в сейфе открыты файлы — спросить, закрыть ли принудительно или не выходить.</summary>
    bool CloseSafeBeforeQuit()
    {
        if (Demo.IsOn || app.Safe.Current?.Mount is not { } mount) return true;
        try
        {
            SecretsVault.Detach(mount);
            return true;
        }
        catch (Exception)
        {
            bool force = Dialogs.Confirm(this, "Сейф не закрывается",
                "В нём открыты файлы в других программах. Offload закрывает сейф, когда выходит сам: закрыть принудительно? Несохранённое в этих программах может пропасть.",
                "Закрыть и выйти", "Не выходить", Tone.Caution, Glyphs.Lock);
            if (!force) return false;
            try { SecretsVault.Detach(mount, force: true); } catch (Exception) { }
            return true;
        }
    }
}
