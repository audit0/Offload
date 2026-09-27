using System.Windows;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Что сообщает строка. Цвет у всего один — чёрный; красный только у ошибки.</summary>
public enum Tone { Good, Caution, Danger, Neutral, Brand, Info }

/// <summary>Общий язык интерфейса — тот же, что у версии для Mac: чёрно-белое стекло. Окно — размытый рабочий стол
/// (Mica в Windows 11) под приглушающей дымкой, карточки — полупрозрачные белые пластины с бликом по кромке,
/// текст тёмный и чёткий. Главные кнопки — тёмные. Цветом ничего не украшается: состояния различаются значками
/// и словами, красный — только ошибка. Тема одна — светлая, при любой теме Windows.</summary>
public static class Theme
{
    public const double PagePadding = 32;
    public const double SectionSpacing = 28;
    public const double CardPadding = 18;
    public const double CardRadius = 18;
    /// <summary>Шире колонка страницы не растягивается: на большом мониторе строки иначе читались бы с трудом.</summary>
    public const double ContentWidth = 980;

    static SolidColorBrush Brush(uint rgb, double opacity = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        brush.Freeze();
        return brush;
    }

    public static readonly SolidColorBrush Ink = Brush(0x111111);
    /// <summary>Второстепенный текст — тёмно-серый: читается так же уверенно, как основной.</summary>
    public static readonly SolidColorBrush Muted = Brush(0x55555A);
    public static readonly SolidColorBrush Faint = Brush(0x6E6E73);
    public static readonly SolidColorBrush Line = Brush(0xD8D8DE);
    public static readonly SolidColorBrush LineSoft = Brush(0xE8E8ED);
    public static readonly SolidColorBrush Bad = Brush(0xD70015);
    public static readonly SolidColorBrush BadSoft = Brush(0xFFF1F1);
    public static readonly SolidColorBrush Panel = Brush(0xF4F4F7);
    /// <summary>Подложка значков, ярлыков, выделенной строки — матовое белое стекло.</summary>
    public static readonly SolidColorBrush Soft = Brush(0xFFFFFF, 0.55);
    public static readonly SolidColorBrush Track = LineSoft;
    public static readonly SolidColorBrush White = Brush(0xFFFFFF);

    public static Brush ToneBrush(Tone tone) => tone switch
    {
        Tone.Danger => Bad,
        Tone.Neutral => Faint,
        _ => Ink,
    };

    /// <summary>Подложка значка и плашки: белая на серой карточке, розоватая — у ошибки.</summary>
    public static Brush ToneSoft(Tone tone) => tone == Tone.Danger ? BadSoft : Soft;
}

/// <summary>Значки из шрифта Segoe Fluent Icons (Windows 11) и Segoe MDL2 Assets (Windows 10) —
/// замена символам SF Symbols у версии для Mac.</summary>
public static class Glyphs
{
    public const string Gauge = "\uEC4A";
    public const string Sparkle = "\uEA99";
    public const string Shield = "\uEA18";
    public const string Chart = "\uE9D2";
    public const string History = "\uE81C";
    public const string Backup = "\uEDA2";
    public const string CloudDownload = "\uEBD3";
    public const string Package = "\uE7B8";
    public const string Lock = "\uE72E";
    public const string Unlock = "\uE785";
    public const string LockSlash = "\uE8D8";
    public const string Error = "\uEA39";
    public const string Warning = "\uE7BA";
    public const string Info = "\uE946";
    public const string Check = "\uE73E";
    public const string CheckCircle = "\uE930";
    public const string CheckSeal = "\uEC61";
    public const string Blocked = "\uE733";
    public const string Close = "\uE711";
    public const string Add = "\uE710";
    public const string Remove = "\uE738";
    public const string Refresh = "\uE72C";
    public const string Search = "\uE721";
    public const string Trash = "\uE74D";
    public const string Folder = "\uE8B7";
    public const string FolderOpen = "\uE838";
    public const string Document = "\uE8A5";
    public const string Copy = "\uE8C8";
    public const string Drive = "\uEDA2";
    public const string DriveExternal = "\uE88E";
    public const string Memory = "\uEEA1";
    public const string Computer = "\uE7F4";
    public const string Lightbulb = "\uE82F";
    public const string List = "\uE8FD";
    public const string Key = "\uE8D7";
    public const string Download = "\uE896";
    public const string Upload = "\uE898";
    public const string Cloud = "\uE753";
    public const string ChevronRight = "\uE76C";
    public const string ChevronLeft = "\uE76B";
    public const string ChevronDown = "\uE70D";
    public const string ChevronUp = "\uE70E";
    public const string Up = "\uE74A";
    public const string ArrowReturn = "\uE7A7";
    public const string Link = "\uE71B";
    public const string Clock = "\uE823";
    public const string Tray = "\uE7B8";
    public const string Stop = "\uE71A";
    public const string Wand = "\uEA99";
    public const string Hand = "\uE733";
    public const string Eye = "\uE890";
    public const string Settings = "\uE713";
    public const string OpenExternal = "\uE8A7";

    /// <summary>Шрифт со значками: на Windows 11 — Segoe Fluent Icons, иначе Segoe MDL2 Assets.</summary>
    public static readonly FontFamily Font = new("Segoe Fluent Icons, Segoe MDL2 Assets");
}

public static class VerdictDisplay
{
    public static string Title(this Verdict verdict) => verdict.Kind switch
    {
        VerdictKind.Safe => "Можно перенести",
        VerdictKind.Caution => "С оговорками",
        _ => "Не трогать",
    };

    public static string Glyph(this Verdict verdict) => verdict.Kind switch
    {
        VerdictKind.Safe => Glyphs.CheckCircle,
        VerdictKind.Caution => Glyphs.Warning,
        _ => Glyphs.Hand,
    };

    public static Tone Tone(this Verdict verdict) => verdict.Kind switch
    {
        VerdictKind.Safe => Offload.Tone.Good,
        VerdictKind.Caution => Offload.Tone.Caution,
        _ => Offload.Tone.Neutral,
    };
}
