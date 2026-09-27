using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Offload;

/// <summary>Режим для разработки: OFFLOAD_DEMO=1 OFFLOAD_SNAPSHOT_DIR=папка OffLoadAI.exe проходит по всем разделам,
/// сохраняет их снимки в PNG и завершает программу. Снимки делаются средствами самого окна.</summary>
public static class Snapshots
{
    public static async Task Run(string directory, Window window, AppModel app)
    {
        Directory.CreateDirectory(directory);
        window.Width = 1180;
        window.Height = 760;
        await Task.Delay(1500);
        if (Environment.GetEnvironmentVariable("OFFLOAD_GLYPHS") == "1")
        {
            foreach (var (name, start) in new[] { ("glyphs-e7", 0xE700), ("glyphs-eb", 0xEB00), ("glyphs-f0", 0xF000), ("glyphs-f4", 0xF400) })
                GlyphSheet(Path.Combine(directory, name + ".png"), start, 1024);
        }
        var wanted = Environment.GetEnvironmentVariable("OFFLOAD_SNAPSHOT_SECTIONS")?.Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(k => SidebarSections.All.FirstOrDefault(s => s.Key() == k.Trim(), (SidebarSection)(-1)))
            .Where(s => (int)s >= 0).ToList();
        foreach (var section in wanted is { Count: > 0 } ? wanted : SidebarSections.All.ToList())
        {
            app.Section = section;
            await Task.Delay(2500);
            Save(window, Path.Combine(directory, section.Key() + ".png"));
        }
        // OFFLOAD_SNAPSHOT_PRO=1 — ещё и окно «Offload Pro», каким его открывает «да» на лишние копии.
        if (Environment.GetEnvironmentVariable("OFFLOAD_SNAPSHOT_PRO") == "1")
        {
            var sheet = new ProSheet(app, Offload.Core.ProFeature.Duplicates) { Owner = window };
            sheet.Show();
            await Task.Delay(1500);
            if (VisualTreeHelper.GetChildrenCount(sheet) > 0 && VisualTreeHelper.GetChild(sheet, 0) is FrameworkElement root)
                Render(root, sheet, Path.Combine(directory, "pro.png"));
            sheet.Close();
        }
        window.Close();
    }

    /// <summary>Таблица значков шрифта — чтобы выбирать их по картинке, а не по памяти.</summary>
    static void GlyphSheet(string path, int start, int count)
    {
        const int columns = 32, cell = 44;
        int rows = count / columns;
        var visual = new DrawingVisual();
        var face = new Typeface(Glyphs.Font, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var label = new Typeface("Consolas");
        using (var context = visual.RenderOpen())
        {
            context.DrawRectangle(Brushes.White, null, new Rect(0, 0, 60 + columns * cell, rows * cell));
            for (int row = 0; row < rows; row++)
            {
                context.DrawText(new FormattedText((start + row * columns).ToString("X4"), System.Globalization.CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight, label, 11, Brushes.Red, 1), new Point(2, row * cell + 14));
                for (int column = 0; column < columns; column++)
                {
                    var text = char.ConvertFromUtf32(start + row * columns + column);
                    context.DrawText(new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, 22,
                        Brushes.Black, 1), new Point(60 + column * cell + 8, row * cell + 6));
                    if (row == 0) { }
                }
            }
            for (int column = 0; column < columns; column += 4)
                context.DrawLine(new Pen(Brushes.LightGray, 1), new Point(60 + column * cell, 0), new Point(60 + column * cell, rows * cell));
        }
        var bitmap = new RenderTargetBitmap(60 + columns * cell, rows * cell, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    public static void Save(Window window, string path)
    {
        if (window.Content is FrameworkElement root) Render(root, window, path);
    }

    static void Render(FrameworkElement root, Window window, string path)
    {
        var dpi = VisualTreeHelper.GetDpi(root);
        int width = (int)Math.Round(root.ActualWidth * dpi.DpiScaleX), height = (int)Math.Round(root.ActualHeight * dpi.DpiScaleY);
        var bitmap = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        // Подложка — цвет окна: фон самого окна в снимок не попадает, а прозрачный PNG выглядел бы иначе.
        var backing = new DrawingVisual();
        using (var context = backing.RenderOpen())
            context.DrawRectangle(window.Background is SolidColorBrush { Color.A: > 0 } brush ? brush : new SolidColorBrush(Color.FromRgb(0xE9, 0xE9, 0xEE)),
                                  null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
        bitmap.Render(backing);
        bitmap.Render(root);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
