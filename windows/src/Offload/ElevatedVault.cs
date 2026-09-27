using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Offload.Core;

namespace Offload;

/// <summary>Запрос к процессу с правами администратора и ответ на него.</summary>
sealed class VaultRequest
{
    public string Op { get; set; } = "";
    public string? Image { get; set; }
    public string? Mount { get; set; }
    public string? Password { get; set; }
    public string? NewPassword { get; set; }
    public string? Label { get; set; }
    public string? Sid { get; set; }
    public long Bytes { get; set; }
    public bool Force { get; set; }
}

sealed class VaultResponse
{
    public bool Ok { get; set; }
    public string? Result { get; set; }
    public VaultErrorKind? ErrorKind { get; set; }
    public string? Error { get; set; }
}

/// <summary>Операции сейфа через отдельный процесс Offload с правами администратора.
///
/// Подключить образ и открыть BitLocker Windows разрешает только администратору. Запускать весь Offload
/// с повышенными правами незачем: права нужны только сейфу. Поэтому при первой операции с сейфом Windows
/// один раз спрашивает разрешение (UAC), запускается второй процесс Offload, и дальше до конца сеанса
/// сейф открывается и закрывается через него — в том числе при сне и блокировке, когда спросить уже нельзя.
///
/// Связь — именованный канал, доступный только этой учётной записи и администраторам. Пароль идёт по каналу,
/// а не в командной строке (её видят другие программы). Каждая сторона проверяет, что на другом конце
/// тот самый процесс: программа — что это запущенный ею помощник, помощник — что это его родитель.
/// Помощник завершается вместе с программой и перед этим закрывает всё, что открыл.</summary>
sealed class ElevatedVault : IVaultBackend, IDisposable
{
    readonly Lock gate = new();
    NamedPipeServerStream? pipe;
    Process? helper;

    static readonly JsonSerializerOptions Json = new();

    public void Create(string image, long maxBytes, string label, string password, string userSid) =>
        Call(new VaultRequest { Op = "create", Image = image, Bytes = maxBytes, Label = label, Password = password, Sid = userSid });

    public string Attach(string image, string password, string userSid) =>
        Call(new VaultRequest { Op = "attach", Image = image, Password = password, Sid = userSid }) ?? throw new VaultException(VaultErrorKind.MountFailed, "нет ответа");

    public void Detach(string mountRoot, bool force) => Call(new VaultRequest { Op = "detach", Mount = mountRoot, Force = force });

    public void Grow(string image, long maxBytes, string password) => Call(new VaultRequest { Op = "grow", Image = image, Bytes = maxBytes, Password = password });

    public string Compact(string image, string password) => Call(new VaultRequest { Op = "compact", Image = image, Password = password }) ?? "";

    public void ChangePassword(string image, string oldPassword, string newPassword) =>
        Call(new VaultRequest { Op = "password", Image = image, Password = oldPassword, NewPassword = newPassword });

    public void TryUnlock(string image, string password) => Call(new VaultRequest { Op = "unlock", Image = image, Password = password });

    /// <summary>Помощник уже запущен: закрыть сейф можно без нового запроса UAC.</summary>
    public bool IsRunning
    {
        get { lock (gate) return pipe is { IsConnected: true } && helper is { HasExited: false }; }
    }

    string? Call(VaultRequest request)
    {
        lock (gate)
        {
            EnsureHelper();
            try
            {
                Write(pipe!, JsonSerializer.SerializeToUtf8Bytes(request, Json));
                var response = JsonSerializer.Deserialize<VaultResponse>(Read(pipe!), Json)
                               ?? throw new VaultException(VaultErrorKind.MountFailed, "помощник не ответил");
                if (response.Ok) return response.Result;
                throw new VaultException(response.ErrorKind ?? VaultErrorKind.MountFailed, response.Error ?? "");
            }
            catch (IOException)
            {
                Reset();
                throw new VaultException(VaultErrorKind.Unavailable, "Процесс Offload с правами администратора закрылся. Повторите — Windows снова спросит разрешение.");
            }
        }
    }

    void EnsureHelper()
    {
        if (pipe is { IsConnected: true } && helper is { HasExited: false }) return;
        Reset();
        var name = "offload-vault-" + Guid.NewGuid().ToString("N");
        var security = new PipeSecurity();
        var user = WindowsIdentity.GetCurrent().User!;
        security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                                                  PipeAccessRights.ReadWrite, AccessControlType.Allow));
        var server = NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
                                                     1 << 16, 1 << 16, security);
        Process? process;
        try
        {
            process = Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
            {
                UseShellExecute = true,
                Verb = "runas",
                Arguments = $"--vault-helper {name} {Environment.ProcessId}",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            server.Dispose();
            throw new VaultException(VaultErrorKind.Unavailable, "Без прав администратора сейф не открыть: Windows спросила разрешение, и его не дали.");
        }
        if (process == null)
        {
            server.Dispose();
            throw new VaultException(VaultErrorKind.Unavailable, "Не удалось запустить Offload с правами администратора.");
        }
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            server.WaitForConnectionAsync(timeout.Token).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            server.Dispose();
            try { process.Kill(); } catch (InvalidOperationException) { }
            throw new VaultException(VaultErrorKind.Unavailable, "Процесс Offload с правами администратора не ответил.");
        }
        // На том конце — запущенный нами помощник, а не кто-то, кто успел подключиться к каналу первым.
        if (!GetNamedPipeClientProcessId(server.SafePipeHandle.DangerousGetHandle(), out var client) || client != process.Id)
        {
            server.Dispose();
            throw new VaultException(VaultErrorKind.Unavailable, "К каналу сейфа подключился чужой процесс — операция отменена.");
        }
        pipe = server;
        helper = process;
    }

    void Reset()
    {
        pipe?.Dispose();
        pipe = null;
        helper?.Dispose();
        helper = null;
    }

    public void Dispose()
    {
        lock (gate) Reset();
    }

    // MARK: Сообщения: длина (4 байта) и JSON.

    internal static void Write(Stream stream, byte[] data)
    {
        Span<byte> length = stackalloc byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(length, data.Length);
        stream.Write(length);
        stream.Write(data);
        stream.Flush();
    }

    internal static byte[] Read(Stream stream)
    {
        Span<byte> length = stackalloc byte[4];
        stream.ReadExactly(length);
        int size = BinaryPrimitives.ReadInt32LittleEndian(length);
        if (size is < 0 or > 1 << 20) throw new IOException("слишком длинное сообщение");
        var data = new byte[size];
        stream.ReadExactly(data);
        return data;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out int processId);
}

/// <summary>Второй процесс Offload с правами администратора: выполняет операции сейфа по просьбе программы.</summary>
static class VaultHelper
{
    public static int Serve(string pipeName, int parentId)
    {
        if (!pipeName.StartsWith("offload-vault-", StringComparison.Ordinal)) return 2;
        Process parent;
        try { parent = Process.GetProcessById(parentId); }
        catch (ArgumentException) { return 2; }
        using var ops = new VaultOps();
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut);
        try { pipe.Connect(10_000); }
        catch (TimeoutException) { return 3; }
        // На том конце — программа, которая нас запустила, а не подменённый канал.
        if (!ElevatedVault.GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var server) || server != parentId) return 4;
        // Программа закрылась (или упала) — закрываем всё, что открыли, и уходим сами.
        var watcher = new Thread(() =>
        {
            parent.WaitForExit();
            ops.DetachAll();
            Environment.Exit(0);
        }) { IsBackground = true };
        watcher.Start();
        while (true)
        {
            VaultRequest? request;
            try { request = JsonSerializer.Deserialize<VaultRequest>(ElevatedVault.Read(pipe)); }
            catch (Exception ex) when (ex is IOException or EndOfStreamException or JsonException) { break; }
            if (request == null) break;
            var response = new VaultResponse();
            try
            {
                response.Result = Execute(ops, request);
                response.Ok = true;
            }
            catch (VaultException ex)
            {
                response.ErrorKind = ex.Kind;
                response.Error = ex.Detail.Length > 0 ? ex.Detail : null;
            }
            catch (Exception ex)
            {
                response.ErrorKind = VaultErrorKind.MountFailed;
                response.Error = ex.Message;
            }
            try { ElevatedVault.Write(pipe, JsonSerializer.SerializeToUtf8Bytes(response)); }
            catch (IOException) { break; }
        }
        ops.DetachAll();
        return 0;
    }

    static string? Execute(VaultOps ops, VaultRequest request)
    {
        string Image() => request.Image is { } image && image.EndsWith(".vhdx", StringComparison.OrdinalIgnoreCase)
            ? image : throw new VaultException(VaultErrorKind.Unavailable, "это не образ сейфа");
        string Password() => request.Password ?? throw new VaultException(VaultErrorKind.WrongPassword);
        switch (request.Op)
        {
            case "create":
                ops.Create(Image(), request.Bytes, request.Label ?? SecretsVault.VolumeName, Password(), request.Sid ?? "");
                return null;
            case "attach":
                return ops.Attach(Image(), Password(), request.Sid ?? "");
            case "detach":
                if (request.Mount is not { Length: 3 } mount || mount[1] != ':' || mount[2] != '\\')
                    throw new VaultException(VaultErrorKind.CloseFailed, "это не корень диска");
                ops.Detach(mount, request.Force);
                return null;
            case "grow":
                ops.Grow(Image(), request.Bytes, Password());
                return null;
            case "compact":
                return ops.Compact(Image(), Password());
            case "password":
                ops.ChangePassword(Image(), Password(), request.NewPassword ?? throw new VaultException(VaultErrorKind.WeakPassword));
                return null;
            case "unlock":
                ops.TryUnlock(Image(), Password());
                return null;
            default:
                throw new VaultException(VaultErrorKind.Unavailable, "неизвестная операция");
        }
    }
}
