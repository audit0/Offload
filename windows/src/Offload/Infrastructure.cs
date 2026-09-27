using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Offload.Core;

namespace Offload;

/// <summary>Основа моделей: свойства, об изменении которых узнаёт интерфейс.</summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        return true;
    }

    /// <summary>Сообщить, что изменились свойства, которые считаются из других.</summary>
    public void Raise(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    /// <summary>Перечитать всё: для свойств, зависящих от многого сразу.</summary>
    public void RaiseAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}

/// <summary>Команда для кнопки: действие и когда оно доступно.</summary>
public sealed class Command(Action<object?> execute, Func<object?, bool>? canExecute = null) : ICommand
{
    public Command(Action execute, Func<bool>? canExecute = null) : this(_ => execute(), canExecute == null ? null : _ => canExecute()) { }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => canExecute?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => execute(parameter);
}

/// <summary>Флаг отмены, который безопасно читать из фоновой работы.</summary>
public sealed class CancelToken
{
    volatile bool cancelled;
    public bool IsCancelled => cancelled;
    public void Cancel() => cancelled = true;
}

/// <summary>Пропускает не чаще одного события за интервал, чтобы прогресс не заваливал интерфейс.</summary>
public sealed class Throttle(double interval = 0.1)
{
    readonly Lock gate = new();
    long last;

    public bool Ready()
    {
        lock (gate)
        {
            long now = Stopwatch.GetTimestamp();
            if (last != 0 && Stopwatch.GetElapsedTime(last, now).TotalSeconds < interval) return false;
            last = now;
            return true;
        }
    }
}

public sealed class Counter
{
    long total;
    public long Add(long value) => Interlocked.Add(ref total, value);
}

public sealed class Collector<T>
{
    readonly Lock gate = new();
    readonly List<T> items = [];
    public void Append(T item) { lock (gate) items.Add(item); }
    public List<T> All { get { lock (gate) return [.. items]; } }
}

public static class Ui
{
    /// <summary>Выполнить на потоке интерфейса — из фоновой работы.</summary>
    public static void Post(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action, DispatcherPriority.Background);
    }

    /// <summary>Показать в Проводнике: открыть папку и выделить объект.</summary>
    public static void Reveal(string path)
    {
        try
        {
            if (FileSystem.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            else if (Directory.Exists(Paths.Parent(path))) Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Paths.Parent(path)}\"") { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { }
    }

    /// <summary>Путь относительно домашней папки: «~\Documents\Фото».</summary>
    public static string RelativeToHome(string path, string home) =>
        Paths.Relative(path, home) is { } relative ? "~\\" + relative : path;
}

/// <summary>Сообщение для человека вместе с тем, как его показывать. Без этого неудача возврата выглядела
/// бы точно так же, как удача.</summary>
public sealed record NoticeMessage(NoticeKind Kind, string Text, IReadOnlyList<string> Details)
{
    public NoticeMessage(NoticeKind kind, string text) : this(kind, text, []) { }
}

public enum NoticeKind { Info, Success, Warning, Error }

/// <summary>Настройки программы — то, что на Mac лежит в UserDefaults: небольшой JSON в %LOCALAPPDATA%\Offload.
/// В демонстрации ничего не сохраняется: вымышленные папки не должны заменить настоящие.</summary>
public static class Settings
{
    static readonly string FilePath = Path.Combine(Paths.LocalAppData, "Offload", "settings.json");
    static readonly Lock gate = new();
    static JsonObject? data;

    static JsonObject Data
    {
        get
        {
            if (data != null) return data;
            try
            {
                if (File.Exists(FilePath)) data = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject;
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { }
            return data ??= new JsonObject();
        }
    }

    public static T? Get<T>(string key)
    {
        lock (gate)
        {
            try { return Data.TryGetPropertyValue(key, out var node) && node != null ? node.Deserialize<T>() : default; }
            catch (JsonException) { return default; }
        }
    }

    public static void Set<T>(string key, T value)
    {
        if (Demo.IsOn) return;
        lock (gate)
        {
            Data[key] = value == null ? null : JsonSerializer.SerializeToNode(value);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                var temporary = FilePath + ".tmp";
                File.WriteAllText(temporary, Data.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                File.Move(temporary, FilePath, overwrite: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }
}
