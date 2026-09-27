using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Пометка «Pro» у кнопки, для которой нужен ключ: контурная капсула цвета текста кнопки.</summary>
public static class ProTag
{
    const string Name = "ProTag";

    static Border Create()
    {
        var tag = new Border
        {
            Name = Name, CornerRadius = new CornerRadius(999), BorderThickness = new Thickness(1), Padding = new Thickness(5, 0, 5, 1),
            Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75,
            ToolTip = "Нужен OffLoadAI Pro",
            Child = new TextBlock { Text = "Pro", FontSize = 10, FontWeight = FontWeights.Bold },
        };
        tag.SetBinding(Border.BorderBrushProperty, new Binding("(TextElement.Foreground)") { RelativeSource = RelativeSource.Self });
        return tag;
    }

    /// <summary>Показать или убрать пометку на кнопке. Надпись-строка превращается в строку с пометкой и обратно.</summary>
    public static void Update(Button button, bool locked)
    {
        if (button.Content is string text)
        {
            if (!locked) return;
            button.Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center } } };
        }
        if (button.Content is not Panel panel) return;
        var existing = panel.Children.OfType<Border>().FirstOrDefault(b => b.Name == Name);
        if (locked && existing == null) panel.Children.Add(Create());
        else if (!locked && existing != null) panel.Children.Remove(existing);
    }
}

/// <summary>Окно «OffLoadAI Pro»: что в нём, что бесплатно всегда, цена, ключ.</summary>
public sealed class ProSheet : SheetWindow
{
    readonly AppModel app;
    readonly ProFeature? reason;
    readonly TextBox keyBox = new() { Tag = "Ключ: OFFLOAD-…" };

    ProModel Pro => app.Pro;

    public ProSheet(AppModel app, ProFeature? reason)
    {
        this.app = app;
        this.reason = reason;
        Width = 540;
        Heading = "OffLoadAI Pro";
        Glyph = Glyphs.CheckSeal;
        keyBox.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) { EnterKey(); e.Handled = true; } };
        Pro.Refresh();
        Build();
        Pro.PropertyChanged += Changed;
        Closed += (_, _) => Pro.PropertyChanged -= Changed;
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ProModel.Status) or nameof(ProModel.KeyProblem)) Build();
    }

    static Style Res(string key) => (Style)Application.Current.FindResource(key);

    void Build()
    {
        var status = Pro.Status;
        Subtitle = status.Kind switch
        {
            ProStatusKind.Licensed => $"Ключ на имя «{status.License!.Name}»",
            ProStatusKind.Early => "Вы пользовались OffLoadAI до Pro — всё открыто навсегда",
            ProStatusKind.Trial => $"Пробный период: осталось {status.DaysLeft} {Plural.Ru(status.DaysLeft, "день", "дня", "дней")}",
            ProStatusKind.Expired => "Обновления по ключу закончились",
            _ => ProModel.Price,
        };

        var body = new StackPanel();
        if (reason is { } feature && !status.IsPro)
        {
            var tail = status.Kind == ProStatusKind.Expired
                ? "Ключ не открывает эту версию — продлите его."
                : "Пробные две недели закончились; всё найденное по-прежнему видно, а «не сейчас» работает как всегда.";
            body.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Info, $"«{feature.Title()}» — в OffLoadAI Pro. {tail}"), Margin = new Thickness(0, 0, 0, 12) });
        }

        var list = new StackPanel();
        for (int i = 0; i < ProFeatures.All.Length; i++)
        {
            var item = ProFeatures.All[i];
            var row = new Grid { Margin = new Thickness(0, 8, 0, 8) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new IconTile { Glyph = FeatureGlyph(item), Tone = status.IsPro ? Tone.Good : Tone.Brand, VerticalAlignment = VerticalAlignment.Top });
            var text = new StackPanel { Margin = new Thickness(12, 0, 8, 0) };
            text.Children.Add(new TextBlock { Text = item.Title(), Style = Res("Body"), FontWeight = FontWeights.Medium });
            text.Children.Add(new TextBlock { Text = item.Detail(), Style = Res("Callout"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            if (status.IsPro)
            {
                var check = new TextBlock { Text = Glyphs.Check, Style = Res("Icon"), VerticalAlignment = VerticalAlignment.Center, ToolTip = "Открыто" };
                Grid.SetColumn(check, 2);
                row.Children.Add(check);
            }
            list.Children.Add(row);
            if (i < ProFeatures.All.Length - 1) list.Children.Add(new Separator { Style = Res("RowDivider"), Margin = new Thickness(40, 0, 0, 0) });
        }
        body.Children.Add(list);
        body.Children.Add(new TextBlock
        {
            Text = "Бесплатно всегда: сейф, перенос со сверкой, возврат перенесённого, очистка мусора и Docker, старые установщики, ключи и токены в сейф, восстановление из iCloud. Вернуть своё OffLoadAI не мешает никогда — ни без ключа, ни после пробы.",
            Style = Res("Callout"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0),
        });
        body.Children.Add(LicenseBlock(status));
        Content = body;

        var buy = new Button { Content = "Купить…", Margin = new Thickness(0, 0, 8, 0) };
        buy.Click += (_, _) => Ui.Open(ProModel.PurchaseUrl);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        if (status.IsPro)
        {
            if (status.Kind != ProStatusKind.Licensed) actions.Children.Add(buy);
            var done = new Button { Content = "Готово", Style = Res("ProminentButton"), IsDefault = true, IsCancel = true };
            done.Click += (_, _) => Close();
            actions.Children.Add(done);
        }
        else
        {
            var close = new Button { Content = "Закрыть", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
            close.Click += (_, _) => Close();
            buy.Style = Res("ProminentButton");
            buy.Margin = new Thickness(0);
            actions.Children.Add(close);
            actions.Children.Add(buy);
        }
        Actions = actions;
    }

    FrameworkElement LicenseBlock(ProStatus status)
    {
        if (status is { Kind: ProStatusKind.Licensed, License: { } license })
        {
            var row = new Grid { Margin = new Thickness(0, 14, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = $"Ключ №{license.Id}. Обновления до {ProModel.Day(license.UpdatesUntil)}.", Style = Res("Callout"),
                TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
            });
            var remove = new Button
            {
                Style = Res("LinkButton"), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
                Content = new TextBlock { Text = "Убрать ключ с этого компьютера", TextDecorations = TextDecorations.Underline },
                ToolTip = "Например, перед продажей компьютера. Ключ остаётся вашим — введите его на новом.",
            };
            remove.Click += (_, _) => Pro.RemoveLicense();
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            return row;
        }
        var block = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        block.Children.Add(new TextBlock
        {
            Text = status.Kind == ProStatusKind.Free ? ProModel.Terms : $"{ProModel.Price}. {ProModel.Terms}",
            Style = Res("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8),
        });
        var entry = new Grid();
        entry.ColumnDefinitions.Add(new ColumnDefinition());
        entry.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (keyBox.Parent is Panel old) old.Children.Remove(keyBox);
        entry.Children.Add(keyBox);
        var enter = new Button { Content = "Ввести ключ", Margin = new Thickness(8, 0, 0, 0), IsEnabled = keyBox.Text.Trim().Length > 0 };
        keyBox.TextChanged += (_, _) => enter.IsEnabled = keyBox.Text.Trim().Length > 0;
        enter.Click += (_, _) => EnterKey();
        Grid.SetColumn(enter, 1);
        entry.Children.Add(enter);
        block.Children.Add(entry);
        if (Pro.KeyProblem is { } problem)
            block.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Error, problem), Margin = new Thickness(0, 8, 0, 0) });
        return block;
    }

    void EnterKey()
    {
        if (keyBox.Text.Trim().Length == 0) return;
        if (Pro.Activate(keyBox.Text)) keyBox.Clear();
    }

    static string FeatureGlyph(ProFeature feature) => feature switch
    {
        ProFeature.Duplicates => Glyphs.Copy,
        ProFeature.Habits => Glyphs.Lightbulb,
        ProFeature.ProjectBackup => Glyphs.Backup,
        _ => Glyphs.Package,
    };
}

/// <summary>Строка над панелью диска: что открыто на этом компьютере. Щелчок — окно «OffLoadAI Pro».</summary>
public sealed class ProSidebarRow : Button
{
    readonly AppModel app;
    readonly TextBlock glyph = new() { FontSize = 14, Width = 20, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock label = new() { FontSize = 12.5, Margin = new Thickness(8, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Border badge = new()
    {
        CornerRadius = new CornerRadius(999), Padding = new Thickness(7, 1, 7, 2), VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = "Pro", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White },
    };

    public ProSidebarRow(AppModel app)
    {
        this.app = app;
        Style = (Style)Application.Current.FindResource("LinkButton");
        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        ToolTip = "OffLoadAI Pro: что в нём и ключ";
        glyph.Style = (Style)Application.Current.FindResource("Icon");
        glyph.Foreground = Theme.Faint;
        label.Foreground = Theme.Ink;
        badge.Background = Theme.Ink;
        var row = new Grid { Height = 30, Margin = new Thickness(6, 0, 6, 0), Background = Brushes.Transparent };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(glyph);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        Grid.SetColumn(badge, 2);
        row.Children.Add(badge);
        Content = row;
        Click += (_, _) => app.Pro.Offer();
        app.Pro.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ProModel.Status)) Update(); };
        Update();
    }

    void Update()
    {
        var pro = app.Pro;
        glyph.Text = pro.IsPro ? Glyphs.CheckSeal : Glyphs.Key;
        label.Text = pro.Summary;
        badge.Visibility = pro.IsPro ? Visibility.Collapsed : Visibility.Visible;
    }
}
