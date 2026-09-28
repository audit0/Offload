using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace Offload;

/// <summary>Вопросы и сведения в листах того же вида, что и всё окно: значок, заголовок, текст, кнопки справа внизу.</summary>
public static class Dialogs
{
    /// <summary>Вопрос с двумя ответами. true — выбрано первое (главное) действие.</summary>
    public static bool Confirm(Window? owner, string title, string text, string primary, string secondary, Tone tone = Tone.Brand,
                               string glyph = Glyphs.Info, bool destructive = false)
    {
        var sheet = new SheetWindow { Heading = title, Glyph = glyph, Tone = tone, Owner = owner ?? Application.Current.MainWindow };
        sheet.Content = new TextBlock { Text = text, Style = (Style)Application.Current.FindResource("Body"), Foreground = Theme.Muted };
        bool result = false;
        var yes = new Button { Content = primary, Style = (Style)Application.Current.FindResource("ProminentButton"), IsDefault = true };
        var no = new Button { Content = secondary, IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        yes.Click += (_, _) => { result = true; sheet.Close(); };
        no.Click += (_, _) => sheet.Close();
        sheet.Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { no, yes } };
        sheet.ShowDialog();
        return result;
    }

    /// <summary>Сведение с одной кнопкой «Готово».</summary>
    public static void Inform(Window? owner, string title, string text, string glyph = Glyphs.Info, Tone tone = Tone.Brand)
    {
        var sheet = new SheetWindow { Heading = title, Glyph = glyph, Tone = tone, Owner = owner ?? Application.Current.MainWindow };
        sheet.Content = new TextBlock { Text = text, Style = (Style)Application.Current.FindResource("Body"), Foreground = Theme.Muted };
        var done = new Button { Content = "Готово", Style = (Style)Application.Current.FindResource("ProminentButton"), IsDefault = true, IsCancel = true };
        done.Click += (_, _) => sheet.Close();
        sheet.Actions = done;
        sheet.ShowDialog();
    }

    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "разработка";

    /// <summary>О программе: версия, ссылки на GitHub и сообщения о новых версиях.</summary>
    public static void About(Window owner, UpdatesModel updates)
    {
        var sheet = new SheetWindow { Heading = "OffLoadAI", Subtitle = $"Версия {Version} для Windows", Glyph = Glyphs.Drive, Owner = owner };
        var body = new StackPanel();
        body.Children.Add(new TextBlock
        {
            Text = "Разгрузка диска без риска потерять данные. Оригинал удаляется только после проверенной копии.",
            Style = (Style)Application.Current.FindResource("Body"),
        });
        var links = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
        foreach (var (label, url) in new[] { ("OffLoadAI на GitHub", App.RepositoryUrl), ("Канал OffLoadAI в Telegram", "https://t.me/OffLoadAI"),
                                             ("Сообщить о проблеме", App.RepositoryUrl + "/issues") })
        {
            var link = new Button { Style = (Style)Application.Current.FindResource("LinkButton"), Margin = new Thickness(0, 0, 18, 0),
                                    Content = new TextBlock { Text = label, TextDecorations = TextDecorations.Underline } };
            link.Click += (_, _) => Ui.Open(url);
            links.Children.Add(link);
        }
        body.Children.Add(links);

        // Сообщения о новых версиях: выключены, пока человек их не включит, — сам OffLoadAI в сеть не ходит.
        var notify = new CheckBox { Content = "Сообщать о новых версиях", IsChecked = updates.Enabled == true, Margin = new Thickness(0, 18, 0, 0) };
        notify.Click += (_, _) => updates.SetEnabled(notify.IsChecked == true);
        body.Children.Add(notify);
        body.Children.Add(new TextBlock
        {
            Text = "Раз в сутки OffLoadAI спросит у GitHub номер последней версии. В запросе нет ничего о компьютере и файлах — GitHub видит только адрес сети.",
            Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        var status = new TextBlock { Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        var check = new Button
        {
            Style = (Style)Application.Current.FindResource("LinkButton"), Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Left,
            Content = new TextBlock { Text = "Проверить обновления сейчас", TextDecorations = TextDecorations.Underline },
        };
        check.Click += async (_, _) =>
        {
            check.IsEnabled = false;
            status.Text = "Спрашиваю GitHub…";
            var message = await updates.CheckNow();
            check.IsEnabled = true;
            status.Text = message ?? "";
            if (message != null || updates.Available == null) return;
            sheet.Close();
            UpdateSheet.Show(owner, updates);
        };
        body.Children.Add(check);
        body.Children.Add(status);

        sheet.Content = body;
        var done = new Button { Content = "Готово", Style = (Style)Application.Current.FindResource("ProminentButton"), IsDefault = true, IsCancel = true };
        done.Click += (_, _) => sheet.Close();
        sheet.Actions = done;
        sheet.ShowDialog();
    }

    /// <summary>Спросить пароль (сейфа или хранилища). null — отказались. Пароль нигде не остаётся:
    /// поле очищается, как только лист закрыт.</summary>
    public static string? AskPassword(Window? owner, string title, string subtitle, string action, string glyph = Glyphs.Lock)
    {
        var sheet = new SheetWindow { Heading = title, Subtitle = subtitle, Glyph = glyph, Owner = owner ?? Application.Current.MainWindow };
        var box = new PasswordBox { Tag = "Пароль" };
        sheet.Content = box;
        string? result = null;
        var ok = new Button { Content = action, Style = (Style)Application.Current.FindResource("ProminentButton"), IsDefault = true };
        var cancel = new Button { Content = "Отменить", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        ok.Click += (_, _) =>
        {
            if (box.Password.Length == 0) return;
            result = box.Password;
            sheet.Close();
        };
        cancel.Click += (_, _) => sheet.Close();
        sheet.Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { cancel, ok } };
        sheet.Loaded += (_, _) => box.Focus();
        sheet.ShowDialog();
        box.Clear();
        return result;
    }
}
