using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Offload.Core;

namespace Offload;

public partial class SafeStatusPanel : UserControl
{
    AppModel? app;
    bool updating;
    Popup? unlock;

    public SafeStatusPanel() => InitializeComponent();

    public AppModel App
    {
        set
        {
            app = value;
            app.PropertyChanged += Changed;
            app.Safe.PropertyChanged += Changed;
            Update();
        }
    }

    void Changed(object? sender, PropertyChangedEventArgs e) => Update();

    void Update()
    {
        if (app == null) return;
        updating = true;
        var volumes = app.Volumes;
        var destination = app.Destination;
        NoDisk.Visibility = volumes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        // Выбор нужен, только когда дисков несколько; один диск — просто его имя.
        bool picker = volumes.Count > 1 || (volumes.Count > 0 && destination == null);
        DiskPicker.Visibility = picker ? Visibility.Visible : Visibility.Collapsed;
        DiskPicker.ItemsSource = volumes;
        DiskPicker.SelectedItem = volumes.FirstOrDefault(v => v.Id == app.DestinationId);
        // Сон, блокировка и простой закрывают сейф выбранного диска. Переключись на другой диск при открытом сейфе —
        // прежний остался бы открытым без присмотра.
        DiskPicker.IsEnabled = !app.Safe.IsOpen && app.Safe.Activity == null;
        DiskPicker.ToolTip = app.Safe.IsOpen ? "Закройте сейф, чтобы выбрать другой диск" : null;
        DiskName.Visibility = !picker && destination != null ? Visibility.Visible : Visibility.Collapsed;
        DiskTitle.Text = destination?.Name ?? "";
        DiskBar.Visibility = destination is { TotalBytes: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        if (destination is { TotalBytes: > 0 } disk) DiskBar.Fraction = (double)(disk.TotalBytes - disk.AvailableBytes) / disk.TotalBytes;
        DiskDetail.Visibility = destination != null ? Visibility.Visible : Visibility.Collapsed;
        DiskDetail.Text = destination != null ? $"{destination.FsDisplayName} · свободно {Format.Bytes(destination.AvailableBytes)}" : "";

        SafeBlock.Visibility = destination != null ? Visibility.Visible : Visibility.Collapsed;
        var safe = app.Safe;
        SafeTile.Glyph = safe.SummaryGlyph;
        SafeTile.Tone = safe.SummaryTone;
        SafeTitle.Text = safe.Summary;
        SafeDetail.Text = Status();
        bool busy = safe.Activity != null;
        SafeSpinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SafeButton.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        if (safe.IsOpen)
        {
            SafeButton.Content = "Закрыть";
            SafeButton.ToolTip = "Закрыть сейф (Ctrl+Shift+L)";
        }
        else if (safe.Current?.IsEncrypted == true)
        {
            SafeButton.Content = "Открыть";
            SafeButton.ToolTip = null;
        }
        else
        {
            SafeButton.Content = "Создать";
            SafeButton.ToolTip = null;
        }
        if (safe.IsOpen && unlock != null) unlock.IsOpen = false;
        ToSafe.IsChecked = app.StoreMode == StoreMode.Safe;
        ToDisk.IsChecked = app.StoreMode == StoreMode.Open;
        updating = false;
    }

    /// <summary>Вторая строка под состоянием: где сейф и сколько в нём места.</summary>
    string Status()
    {
        var safe = app!.Safe;
        if (safe.Current is not { Exists: true } state) return $"на «{app.Destination?.Name}»";
        if (!state.IsEncrypted) return "класть в него нельзя";
        if (app.SafeVolume is { } volume) return $"свободно {Format.Bytes(volume.AvailableBytes)}";
        return $"«{state.DisplayName}»";
    }

    void DiskPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updating || app == null || DiskPicker.SelectedItem is not VolumeInfo volume) return;
        app.DestinationId = volume.Id;
    }

    void Store_Checked(object sender, RoutedEventArgs e)
    {
        if (updating || app == null) return;
        app.StoreMode = ToSafe.IsChecked == true ? StoreMode.Safe : StoreMode.Open;
    }

    void SafeButton_Click(object sender, RoutedEventArgs e)
    {
        if (app == null) return;
        var safe = app.Safe;
        if (safe.IsOpen)
        {
            safe.Close(app);
            return;
        }
        if (safe.Current?.IsEncrypted != true)
        {
            app.Section = SidebarSection.Safe;
            return;
        }
        // Открыть сейф прямо здесь — во всплывающей панели справа от кнопки.
        var row = new SafeUnlockRow { Width = 300 };
        var body = new StackPanel();
        var header = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.Children.Add(new IconTile { Glyph = Glyphs.Lock, Tone = Tone.Good, Size = 32 });
        var titles = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = "Открыть сейф", Style = (Style)FindResource("Headline") });
        titles.Children.Add(new TextBlock { Text = $"«{safe.Current?.DisplayName}»", Style = (Style)FindResource("Caption") });
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        body.Children.Add(header);
        body.Children.Add(row);
        unlock = new Popup
        {
            PlacementTarget = SafeButton,
            Placement = PlacementMode.Right,
            HorizontalOffset = 8,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = new Card { Padding = new Thickness(16), Content = body, Background = System.Windows.Media.Brushes.White, Margin = new Thickness(12) },
            IsOpen = true,
        };
        unlock.Opened += (_, _) => row.FocusPassword();
    }
}
