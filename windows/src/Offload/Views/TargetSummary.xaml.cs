using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

public partial class TargetSummary : UserControl
{
    AppModel App => Offload.App.Model;

    /// <summary>Каким тоном показать, что класть некуда: в окне переноса это то, что мешает перенести.</summary>
    public Tone ProblemTone { get; set; } = Tone.Neutral;

    public TargetSummary()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            App.PropertyChanged += Changed;
            App.Safe.PropertyChanged += Changed;
            Update();
        };
        Unloaded += (_, _) =>
        {
            App.PropertyChanged -= Changed;
            App.Safe.PropertyChanged -= Changed;
        };
    }

    void Changed(object? sender, PropertyChangedEventArgs e) => Update();

    void Update()
    {
        if (App.Target is { } target)
        {
            Visibility = Visibility.Visible;
            if (target.IsEncryptedImage) Set(Glyphs.Lock, Tone.Good, $"В сейф «{target.Name}»", $"зашифровано · свободно {Format.Bytes(target.AvailableBytes)}");
            else Set(Glyphs.Unlock, Tone.Caution, $"На диск «{target.Name}» открыто", $"не зашифровано · свободно {Format.Bytes(target.AvailableBytes)}");
        }
        else if (App.TargetProblem is { } problem)
        {
            Visibility = Visibility.Visible;
            Set(Glyphs.LockSlash, ProblemTone, problem, null);
        }
        else Visibility = Visibility.Collapsed;
    }

    void Set(string glyph, Tone tone, string title, string? detail)
    {
        Tile.Glyph = glyph;
        Tile.Tone = tone;
        Title.Text = title;
        Detail.Text = detail ?? "";
        Detail.Visibility = detail == null ? Visibility.Collapsed : Visibility.Visible;
    }
}
