using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Shapes;
using Offload.Core;

namespace Offload;

/// <summary>Карточка — основной строительный блок страниц: стеклянная пластина со скруглением 18.
/// Выделенная (Tint) — с тёмной рамкой для предупреждений, у ошибки — розоватая.</summary>
public class Card : ContentControl
{
    static Card() => DefaultStyleKeyProperty.OverrideMetadata(typeof(Card), new FrameworkPropertyMetadata(typeof(Card)));

    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(nameof(Tint), typeof(Tone?), typeof(Card),
        new PropertyMetadata(null, (d, _) => ((Card)d).UpdateTint()));
    public Tone? Tint { get => (Tone?)GetValue(TintProperty); set => SetValue(TintProperty, value); }

    public static readonly DependencyPropertyKey HighlightKey = DependencyProperty.RegisterReadOnly(nameof(Highlight), typeof(Brush), typeof(Card),
        new PropertyMetadata(Brushes.Transparent));
    public static readonly DependencyProperty HighlightProperty = HighlightKey.DependencyProperty;
    public Brush Highlight => (Brush)GetValue(HighlightKey.DependencyProperty);

    void UpdateTint()
    {
        SetValue(HighlightKey, Tint switch
        {
            null => Brushes.Transparent,
            Tone.Danger => new SolidColorBrush(Color.FromArgb(0x66, 0xD7, 0x00, 0x15)),
            _ => new SolidColorBrush(Color.FromArgb(0xB3, 0x11, 0x11, 0x11)),
        });
        if (Tint == Tone.Danger) Background = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xF1, 0xF1));
    }
}

/// <summary>Раздел страницы: заголовок над карточкой, как в Параметрах Windows, и пояснение под ней.
/// Строки внутри отбиваются разделителями и сами задают себе поля.</summary>
public class CardSection : HeaderedContentControl
{
    static CardSection() => DefaultStyleKeyProperty.OverrideMetadata(typeof(CardSection), new FrameworkPropertyMetadata(typeof(CardSection)));

    public static readonly DependencyProperty FooterProperty = DependencyProperty.Register(nameof(Footer), typeof(string), typeof(CardSection));
    public string? Footer { get => (string?)GetValue(FooterProperty); set => SetValue(FooterProperty, value); }

    /// <summary>Номер шага, если раздел — часть последовательности.</summary>
    public static readonly DependencyProperty NumberProperty = DependencyProperty.Register(nameof(Number), typeof(int?), typeof(CardSection));
    public int? Number { get => (int?)GetValue(NumberProperty); set => SetValue(NumberProperty, value); }
}

/// <summary>Строка карточки-списка: название с пояснением слева, управление справа (Content).</summary>
public class FormRow : ContentControl
{
    static FormRow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(FormRow), new FrameworkPropertyMetadata(typeof(FormRow)));

    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(FormRow));
    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }

    public static readonly DependencyProperty DetailProperty = DependencyProperty.Register(nameof(Detail), typeof(string), typeof(FormRow));
    public string? Detail { get => (string?)GetValue(DetailProperty); set => SetValue(DetailProperty, value); }
}

/// <summary>Название и значение в одну строку, значение прижато вправо.</summary>
public class InfoRow : ContentControl
{
    static InfoRow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(InfoRow), new FrameworkPropertyMetadata(typeof(InfoRow)));

    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(InfoRow));
    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
}

/// <summary>Значок на скруглённой подложке своего цвета — опознавательный знак строки или карточки.</summary>
public class IconTile : Control
{
    static IconTile() => DefaultStyleKeyProperty.OverrideMetadata(typeof(IconTile), new FrameworkPropertyMetadata(typeof(IconTile)));

    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(IconTile));
    public string? Glyph { get => (string?)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }

    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(Tone), typeof(IconTile),
        new PropertyMetadata(Tone.Brand));
    public Tone Tone { get => (Tone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }

    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(nameof(Size), typeof(double), typeof(IconTile),
        new PropertyMetadata(28.0));
    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }
}

/// <summary>Короткое состояние в капсуле: «Можно перенести», «Возвращено», «Сейф закрыт».</summary>
public class StatusPill : Control
{
    static StatusPill() => DefaultStyleKeyProperty.OverrideMetadata(typeof(StatusPill), new FrameworkPropertyMetadata(typeof(StatusPill)));

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(StatusPill));
    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }

    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(StatusPill));
    public string? Glyph { get => (string?)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }

    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(Tone), typeof(StatusPill),
        new PropertyMetadata(Tone.Neutral));
    public Tone Tone { get => (Tone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }

    /// <summary>Плашка по решению правил: «Можно перенести», «С оговорками», «Не трогать» — с оговорками во всплывающей подсказке.</summary>
    public static readonly DependencyProperty VerdictProperty = DependencyProperty.Register(nameof(Verdict), typeof(Verdict), typeof(StatusPill),
        new PropertyMetadata(null, (d, e) =>
        {
            if (e.NewValue is not Verdict verdict) return;
            var pill = (StatusPill)d;
            pill.Text = verdict.Title();
            pill.Glyph = verdict.Glyph();
            pill.Tone = verdict.Tone();
            pill.ToolTip = verdict.Notes.Count > 0 ? string.Join("\n", verdict.Notes) : null;
        }));
    public Verdict? Verdict { get => (Verdict?)GetValue(VerdictProperty); set => SetValue(VerdictProperty, value); }
}

/// <summary>Сообщение: значок по виду (успех, предупреждение, ошибка), текст и оговорки — каждая отдельной строкой.</summary>
public class NoticeView : Control
{
    static NoticeView() => DefaultStyleKeyProperty.OverrideMetadata(typeof(NoticeView), new FrameworkPropertyMetadata(typeof(NoticeView)));

    public static readonly DependencyProperty MessageProperty = DependencyProperty.Register(nameof(Message), typeof(NoticeMessage), typeof(NoticeView),
        new PropertyMetadata(null, (d, _) => ((NoticeView)d).Update()));
    public NoticeMessage? Message { get => (NoticeMessage?)GetValue(MessageProperty); set => SetValue(MessageProperty, value); }

    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(nameof(Kind), typeof(NoticeKind), typeof(NoticeView),
        new PropertyMetadata(NoticeKind.Info, (d, _) => ((NoticeView)d).Update()));
    public NoticeKind Kind { get => (NoticeKind)GetValue(KindProperty); set => SetValue(KindProperty, value); }

    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(NoticeView));
    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }

    public static readonly DependencyProperty DetailsProperty = DependencyProperty.Register(nameof(Details), typeof(IEnumerable<string>), typeof(NoticeView));
    public IEnumerable<string>? Details { get => (IEnumerable<string>?)GetValue(DetailsProperty); set => SetValue(DetailsProperty, value); }

    static readonly DependencyPropertyKey GlyphKey = DependencyProperty.RegisterReadOnly(nameof(Glyph), typeof(string), typeof(NoticeView),
        new PropertyMetadata(Glyphs.Info));
    public static readonly DependencyProperty GlyphProperty = GlyphKey.DependencyProperty;
    public string Glyph => (string)GetValue(GlyphKey.DependencyProperty);

    static readonly DependencyPropertyKey AccentKey = DependencyProperty.RegisterReadOnly(nameof(Accent), typeof(Brush), typeof(NoticeView),
        new PropertyMetadata(Theme.Ink));
    public static readonly DependencyProperty AccentProperty = AccentKey.DependencyProperty;
    public Brush Accent => (Brush)GetValue(AccentKey.DependencyProperty);

    void Update()
    {
        var kind = Message?.Kind ?? Kind;
        if (Message != null)
        {
            SetCurrentValue(TextProperty, Message.Text);
            SetCurrentValue(DetailsProperty, Message.Details.Select(d => "— " + d).ToList());
        }
        SetValue(GlyphKey, kind switch
        {
            NoticeKind.Success => Glyphs.CheckSeal,
            NoticeKind.Warning => Glyphs.Warning,
            NoticeKind.Error => Glyphs.Error,
            _ => Glyphs.Info,
        });
        SetValue(AccentKey, kind == NoticeKind.Error ? Theme.Bad : Theme.Ink);
        Background = kind == NoticeKind.Error ? Theme.BadSoft : new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF));
        BorderBrush = kind == NoticeKind.Error ? Brushes.Transparent : Theme.Line;
    }

    public NoticeView() => Update();
}

/// <summary>Горизонтальная шкала заполнения; совсем маленькая доля видна точкой.</summary>
public class CapacityBar : FrameworkElement
{
    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(nameof(Fraction), typeof(double), typeof(CapacityBar),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }

    public static readonly DependencyProperty BarHeightProperty = DependencyProperty.Register(nameof(BarHeight), typeof(double), typeof(CapacityBar),
        new FrameworkPropertyMetadata(6.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public double BarHeight { get => (double)GetValue(BarHeightProperty); set => SetValue(BarHeightProperty, value); }

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(nameof(Fill), typeof(Brush), typeof(CapacityBar),
        new FrameworkPropertyMetadata(Theme.Ink, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Fill { get => (Brush)GetValue(FillProperty); set => SetValue(FillProperty, value); }

    protected override Size MeasureOverride(Size availableSize) => new(0, BarHeight);

    protected override void OnRender(DrawingContext context)
    {
        double width = ActualWidth, height = BarHeight, radius = height / 2;
        context.DrawRoundedRectangle(Theme.Track, null, new Rect(0, 0, width, height), radius, radius);
        double fraction = Math.Clamp(double.IsNaN(Fraction) ? 0 : Fraction, 0, 1);
        if (fraction <= 0) return;
        double end = Math.Min(width, Math.Max(width * fraction, height));
        context.DrawRoundedRectangle(Fill, null, new Rect(0, 0, end, height), radius, radius);
    }
}

/// <summary>Кольцевая шкала с подписью в середине (Content).</summary>
public class RingGauge : ContentControl
{
    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(nameof(Fraction), typeof(double), typeof(RingGauge),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Fraction { get => (double)GetValue(FractionProperty); set => SetValue(FractionProperty, value); }

    public static readonly DependencyProperty ThicknessProperty = DependencyProperty.Register(nameof(Thickness), typeof(double), typeof(RingGauge),
        new FrameworkPropertyMetadata(7.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Thickness { get => (double)GetValue(ThicknessProperty); set => SetValue(ThicknessProperty, value); }

    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(nameof(Tint), typeof(Brush), typeof(RingGauge),
        new FrameworkPropertyMetadata(Theme.Ink, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Tint { get => (Brush)GetValue(TintProperty); set => SetValue(TintProperty, value); }

    public RingGauge()
    {
        HorizontalContentAlignment = HorizontalAlignment.Center;
        VerticalContentAlignment = VerticalAlignment.Center;
    }

    protected override void OnRender(DrawingContext context)
    {
        double size = Math.Min(ActualWidth, ActualHeight);
        double radius = (size - Thickness) / 2;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        context.DrawEllipse(null, new Pen(Theme.Track, Thickness), center, radius, radius);
        double fraction = Math.Clamp(Fraction, 0, 1);
        if (fraction <= 0) return;
        var pen = new Pen(Tint, Thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (fraction >= 0.9999)
        {
            context.DrawEllipse(null, pen, center, radius, radius);
            return;
        }
        double angle = fraction * 2 * Math.PI;
        var start = new Point(center.X, center.Y - radius);
        var end = new Point(center.X + radius * Math.Sin(angle), center.Y - radius * Math.Cos(angle));
        var figure = new PathFigure { StartPoint = start, IsClosed = false };
        figure.Segments.Add(new ArcSegment(end, new Size(radius, radius), 0, fraction > 0.5, SweepDirection.Clockwise, true));
        context.DrawGeometry(null, pen, new PathGeometry([figure]));
    }
}

/// <summary>Шкала из нескольких частей подряд: на что делится занятое место.</summary>
public class StackedBar : FrameworkElement
{
    public sealed record Part(double Fraction, Brush Brush);

    public static readonly DependencyProperty PartsProperty = DependencyProperty.Register(nameof(Parts), typeof(IReadOnlyList<Part>), typeof(StackedBar),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public IReadOnlyList<Part>? Parts { get => (IReadOnlyList<Part>?)GetValue(PartsProperty); set => SetValue(PartsProperty, value); }

    public static readonly DependencyProperty BarHeightProperty = DependencyProperty.Register(nameof(BarHeight), typeof(double), typeof(StackedBar),
        new FrameworkPropertyMetadata(8.0, FrameworkPropertyMetadataOptions.AffectsMeasure));
    public double BarHeight { get => (double)GetValue(BarHeightProperty); set => SetValue(BarHeightProperty, value); }

    protected override Size MeasureOverride(Size availableSize) => new(0, BarHeight);

    protected override void OnRender(DrawingContext context)
    {
        double width = ActualWidth, height = BarHeight, radius = height / 2;
        var clip = new RectangleGeometry(new Rect(0, 0, width, height), radius, radius);
        context.PushClip(clip);
        context.DrawRectangle(Theme.Track, null, new Rect(0, 0, width, height));
        double x = 0;
        foreach (var part in Parts ?? [])
        {
            double w = Math.Max(0, part.Fraction) * width;
            context.DrawRectangle(part.Brush, null, new Rect(x, 0, w, height));
            x += w;
        }
        context.Pop();
    }
}

/// <summary>Шкала стойкости пароля с советами, что именно его ослабляет.</summary>
public class PasswordStrengthView : Control
{
    static PasswordStrengthView() => DefaultStyleKeyProperty.OverrideMetadata(typeof(PasswordStrengthView), new FrameworkPropertyMetadata(typeof(PasswordStrengthView)));

    public static readonly DependencyProperty PasswordProperty = DependencyProperty.Register(nameof(Password), typeof(string), typeof(PasswordStrengthView),
        new PropertyMetadata("", (d, _) => ((PasswordStrengthView)d).Update()));
    public string Password { get => (string)GetValue(PasswordProperty); set => SetValue(PasswordProperty, value); }

    static readonly DependencyPropertyKey SummaryKey = DependencyProperty.RegisterReadOnly(nameof(Summary), typeof(string), typeof(PasswordStrengthView),
        new PropertyMetadata("Введите пароль"));
    public static readonly DependencyProperty SummaryProperty = SummaryKey.DependencyProperty;
    public string Summary => (string)GetValue(SummaryKey.DependencyProperty);

    static readonly DependencyPropertyKey AdviceKey = DependencyProperty.RegisterReadOnly(nameof(Advice), typeof(IReadOnlyList<string>), typeof(PasswordStrengthView),
        new PropertyMetadata(Array.Empty<string>()));
    public static readonly DependencyProperty AdviceProperty = AdviceKey.DependencyProperty;
    public IReadOnlyList<string> Advice => (IReadOnlyList<string>)GetValue(AdviceKey.DependencyProperty);

    static readonly DependencyPropertyKey SegmentsKey = DependencyProperty.RegisterReadOnly(nameof(Segments), typeof(IReadOnlyList<Brush>), typeof(PasswordStrengthView),
        new PropertyMetadata(Array.Empty<Brush>()));
    public static readonly DependencyProperty SegmentsProperty = SegmentsKey.DependencyProperty;
    /// <summary>Четыре деления — четыре уровня: слабый, так себе, хороший, надёжный.</summary>
    public IReadOnlyList<Brush> Segments => (IReadOnlyList<Brush>)GetValue(SegmentsKey.DependencyProperty);

    static readonly DependencyPropertyKey AccentKey = DependencyProperty.RegisterReadOnly(nameof(Accent), typeof(Brush), typeof(PasswordStrengthView),
        new PropertyMetadata(Theme.Muted));
    public static readonly DependencyProperty AccentProperty = AccentKey.DependencyProperty;
    public Brush Accent => (Brush)GetValue(AccentKey.DependencyProperty);

    public PasswordStrengthView() => Update();

    void Update()
    {
        var password = Password ?? "";
        var strength = PasswordStrength.Evaluate(password);
        int filled = password.Length == 0 ? 0 : (int)strength.Level + 1;
        var color = strength.Level == PasswordLevel.Weak ? Theme.Bad : Theme.Ink;
        SetValue(SegmentsKey, Enumerable.Range(0, 4).Select(i => (Brush)(i < filled ? color : Theme.Track)).ToList());
        SetValue(SummaryKey, password.Length == 0 ? "Введите пароль" : $"{strength.Title} · ≈{(int)strength.Bits} бит");
        SetValue(AccentKey, password.Length == 0 ? Theme.Muted : color);
        SetValue(AdviceKey, strength.Advice);
    }
}

/// <summary>Лист: значок и заголовок сверху, содержимое, кнопки внизу справа под чертой.</summary>
public class SheetWindow : Window
{
    static SheetWindow() => DefaultStyleKeyProperty.OverrideMetadata(typeof(SheetWindow), new FrameworkPropertyMetadata(typeof(SheetWindow)));

    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(SheetWindow),
        new PropertyMetadata(Glyphs.Info));
    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }

    public static readonly DependencyProperty ToneProperty = DependencyProperty.Register(nameof(Tone), typeof(Tone), typeof(SheetWindow),
        new PropertyMetadata(Tone.Brand));
    public Tone Tone { get => (Tone)GetValue(ToneProperty); set => SetValue(ToneProperty, value); }

    public static readonly DependencyProperty HeadingProperty = DependencyProperty.Register(nameof(Heading), typeof(string), typeof(SheetWindow));
    public string? Heading { get => (string?)GetValue(HeadingProperty); set => SetValue(HeadingProperty, value); }

    public static readonly DependencyProperty SubtitleProperty = DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(SheetWindow));
    public string? Subtitle { get => (string?)GetValue(SubtitleProperty); set => SetValue(SubtitleProperty, value); }

    public static readonly DependencyProperty ActionsProperty = DependencyProperty.Register(nameof(Actions), typeof(object), typeof(SheetWindow));
    public object? Actions { get => GetValue(ActionsProperty); set => SetValue(ActionsProperty, value); }

    public SheetWindow()
    {
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MaxHeight = Math.Max(320, SystemParameters.WorkArea.Height - 48);
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Owner = Application.Current?.MainWindow is { IsLoaded: true } main && !ReferenceEquals(main, this) ? main : null;
        Title = "OffLoadAI";
    }
}

// MARK: Преобразователи для привязок

public sealed class BytesConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        long bytes => Format.Bytes(bytes),
        int bytes => Format.Bytes(bytes),
        ulong memory => Format.Memory(memory),
        _ => "",
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class RelativeDateConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is DateTime date ? Format.Relative(date) : "";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>true / непустое / не null → видно. Параметр «not» — наоборот.</summary>
public sealed class VisibleConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        bool visible = value switch
        {
            null => false,
            bool flag => flag,
            string text => text.Length > 0,
            int number => number != 0,
            long number => number != 0,
            System.Collections.ICollection collection => collection.Count > 0,
            _ => true,
        };
        if (parameter as string == "not") visible = !visible;
        return visible ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class NotConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is bool flag ? !flag : value == null;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => value is bool flag ? !flag : false;
}

public sealed class ToneBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Tone tone ? (parameter as string == "soft" ? Theme.ToneSoft(tone) : Theme.ToneBrush(tone)) : Theme.Ink;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Размер значка — чуть меньше половины подложки; скругление — чуть больше четверти.</summary>
public sealed class ScaleConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        double factor = double.Parse((string)parameter!, CultureInfo.InvariantCulture);
        double size = value is double d ? d : 0;
        return targetType == typeof(CornerRadius) ? new CornerRadius(size * factor) : size * factor;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Подсказка в пустом поле пароля: у PasswordBox нет своего признака «пусто», поэтому он ведётся здесь.
/// Текст подсказки — в Tag поля.</summary>
public static class PasswordHint
{
    public static readonly DependencyProperty IsEmptyProperty = DependencyProperty.RegisterAttached("IsEmpty", typeof(bool), typeof(PasswordHint),
        new PropertyMetadata(true));
    public static bool GetIsEmpty(DependencyObject target) => (bool)target.GetValue(IsEmptyProperty);
    public static void SetIsEmpty(DependencyObject target, bool value) => target.SetValue(IsEmptyProperty, value);

    public static readonly DependencyProperty TrackProperty = DependencyProperty.RegisterAttached("Track", typeof(bool), typeof(PasswordHint),
        new PropertyMetadata(false, (d, e) =>
        {
            if (d is not PasswordBox box) return;
            box.PasswordChanged -= Changed;
            if ((bool)e.NewValue) box.PasswordChanged += Changed;
            SetIsEmpty(box, box.Password.Length == 0);
        }));
    public static bool GetTrack(DependencyObject target) => (bool)target.GetValue(TrackProperty);
    public static void SetTrack(DependencyObject target, bool value) => target.SetValue(TrackProperty, value);

    static void Changed(object sender, RoutedEventArgs e)
    {
        var box = (PasswordBox)sender;
        SetIsEmpty(box, box.Password.Length == 0);
    }
}
