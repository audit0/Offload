using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Offload;

/// <summary>Строка в боковой колонке: вышла новая версия. Пока новой нет, строки не видно.</summary>
public sealed class UpdateSidebarRow : Button
{
    readonly AppModel app;
    readonly TextBlock label = new()
    {
        FontSize = 12.5, FontWeight = FontWeights.Medium, Margin = new Thickness(8, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    public UpdateSidebarRow(AppModel app)
    {
        this.app = app;
        Style = (Style)Application.Current.FindResource("LinkButton");
        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        // Отступ — у самой строки: пока новой версии нет, строка скрыта вместе с ним.
        Margin = new Thickness(0, 0, 0, 4);
        ToolTip = "Что нового и как обновиться";
        var glyph = new TextBlock
        {
            Style = (Style)Application.Current.FindResource("Icon"), Text = Glyphs.Download, FontSize = 14, Width = 20,
            TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Theme.Ink,
        };
        label.Foreground = Theme.Ink;
        var row = new Grid { Height = 30, Margin = new Thickness(6, 0, 6, 0), Background = Brushes.Transparent };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(glyph);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        Content = row;
        Click += (_, _) => UpdateSheet.Show(Window.GetWindow(this), app.Updates);
        app.Updates.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(UpdatesModel.Available)) Update(); };
        Update();
    }

    void Update()
    {
        var release = app.Updates.Available;
        Visibility = release == null ? Visibility.Collapsed : Visibility.Visible;
        label.Text = release == null ? "" : $"Вышла версия {release.Version}";
    }
}

/// <summary>Вышла новая версия: что нового — на странице выпуска, обновиться — командой в PowerShell.</summary>
public static class UpdateSheet
{
    public static void Show(Window? owner, UpdatesModel updates)
    {
        if (updates.Available is not { } release) return;
        var sheet = new SheetWindow
        {
            Heading = $"Вышла версия {release.Version}", Subtitle = $"У вас — {Dialogs.Version}", Glyph = Glyphs.Download,
            Owner = owner ?? Application.Current.MainWindow,
        };
        var body = new StackPanel();
        body.Children.Add(new TextBlock
        {
            Text = "Чтобы обновиться, вставьте эту команду в PowerShell. Она скачает новую версию, сверит её и поставит на место этой — "
                 + "сначала попросив OffLoadAI закрыться. Настройки, ключ Pro, журнал и сейф останутся как были.",
            Style = (Style)Application.Current.FindResource("Body"), Foreground = Theme.Muted,
        });
        body.Children.Add(new TextBox
        {
            Text = UpdatesModel.InstallCommand, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 12, 0, 0),
        });
        var copy = new Button { Content = "Скопировать", Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        copy.Click += (_, _) =>
        {
            // Буфер обмена может держать другая программа — тогда пусть человек выделит команду сам.
            try
            {
                Clipboard.SetText(UpdatesModel.InstallCommand);
                copy.Content = "Скопировано";
            }
            catch (COMException) { copy.Content = "Не вышло — выделите команду и скопируйте"; }
        };
        body.Children.Add(copy);
        sheet.Content = body;

        var notes = new Button { Content = "Что нового", Margin = new Thickness(0, 0, 8, 0) };
        notes.Click += (_, _) => Ui.Open(release.Page);
        var later = new Button { Content = "Не напоминать об этой", Margin = new Thickness(0, 0, 8, 0) };
        later.Click += (_, _) =>
        {
            updates.Postpone();
            sheet.Close();
        };
        var done = new Button { Content = "Готово", Style = (Style)Application.Current.FindResource("ProminentButton"), IsDefault = true, IsCancel = true };
        done.Click += (_, _) => sheet.Close();
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(notes);
        actions.Children.Add(later);
        actions.Children.Add(done);
        sheet.Actions = actions;
        sheet.ShowDialog();
    }
}
