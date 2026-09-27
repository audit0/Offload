using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

/// <summary>«Да» на вопрос о сейфе, а он закрыт: пароль — и перенос начнётся, как только сейф откроется.</summary>
public sealed class CleanupSafeSheet : SheetWindow
{
    readonly AppModel app;
    readonly Action onOpen;
    bool opened;

    public CleanupSafeSheet(AppModel app, long bytes, Action onOpen)
    {
        this.app = app;
        this.onOpen = onOpen;
        Heading = "Откройте сейф";
        Subtitle = $"Убрать в сейф {Format.Bytes(bytes)}";
        Glyph = Glyphs.Lock;
        Tone = Tone.Good;
        Owner ??= Application.Current?.MainWindow;

        var safe = app.Safe;
        var body = new StackPanel();
        string text;
        SafeUnlockRow? row = null;
        if (app.Destination == null)
            text = "Подключите внешний диск, на котором лежит сейф, и ответьте ещё раз. Остальные вопросы от этого не зависят.";
        else if (!safe.Exists)
            text = $"На диске «{app.Destination?.Name}» сейфа нет. Создайте его в разделе «Сейф» и ответьте ещё раз.";
        else if (safe.Current?.IsEncrypted != true)
            text = "Шифрование образа на диске не подтверждается — класть в него нельзя. Разберитесь в разделе «Сейф».";
        else
        {
            text = "Пароль нужен, чтобы убрать это в сейф. Он уходит в BitLocker и нигде не сохраняется. Как только сейф откроется, начну.";
            row = new SafeUnlockRow { Margin = new Thickness(0, 14, 0, 0) };
        }
        body.Children.Add(new TextBlock { Text = text, Style = (Style)FindResource("Callout") });
        if (row != null) body.Children.Add(row);
        Content = body;

        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        var cancel = new Button { Content = "Отмена", IsCancel = true };
        cancel.Click += (_, _) => Close();
        actions.Children.Add(cancel);
        if (app.Destination != null && !safe.Exists)
        {
            var open = new Button { Content = "Открыть «Сейф»", Style = (Style)FindResource("ProminentButton"), Margin = new Thickness(8, 0, 0, 0) };
            open.Click += (_, _) =>
            {
                Close();
                app.Section = SidebarSection.Safe;
            };
            actions.Children.Add(open);
        }
        Actions = actions;

        safe.PropertyChanged += Safe_Changed;
        Closed += (_, _) => safe.PropertyChanged -= Safe_Changed;
        if (row != null) Loaded += (_, _) => row.FocusPassword();
    }

    void Safe_Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (opened || !app.Safe.IsOpen) return;
        opened = true;
        // Сначала закрыть лист, потом начать: иначе перенос шёл бы под окном, которое уже не нужно.
        Dispatcher.BeginInvoke(() =>
        {
            Close();
            onOpen();
        });
    }
}
