using System.Reflection;

namespace Offload.Core;

/// <summary>Состояние BitLocker тома так, как его показывает Проводник (значок замка).
/// Прав администратора не нужно: это свойство оболочки System.Volume.BitLockerProtection.</summary>
public readonly record struct BitLockerProtection(int Value)
{
    /// <summary>1 — включён и открыт, 3 — идёт шифрование, 5 — приостановлен, 6 — включён и заблокирован.</summary>
    public bool IsEncrypted => Value is 1 or 3 or 6;
    public bool IsLocked => Value == 6;
    public bool IsSuspended => Value == 5;
}

public static class BitLockerShell
{
    /// <summary>null — у тома нет BitLocker или Windows не ответила.</summary>
    public static BitLockerProtection? Protection(string root)
    {
        object? value = null;
        // Объекты оболочки живут в однопоточном апартаменте: спрашиваем из своего потока STA.
        var thread = new Thread(() =>
        {
            try
            {
                var type = Type.GetTypeFromProgID("Shell.Application");
                if (type == null) return;
                var shell = Activator.CreateInstance(type);
                var computer = type.InvokeMember("NameSpace", BindingFlags.InvokeMethod, null, shell, [17]);
                if (computer == null) return;
                var item = computer.GetType().InvokeMember("ParseName", BindingFlags.InvokeMethod, null, computer,
                                                           [root.TrimEnd('\\') + "\\"]);
                if (item == null) return;
                value = item.GetType().InvokeMember("ExtendedProperty", BindingFlags.InvokeMethod, null, item,
                                                    ["System.Volume.BitLockerProtection"]);
            }
            catch (Exception ex) when (ex is TargetInvocationException or System.Runtime.InteropServices.COMException or MissingMethodException) { }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        if (!thread.Join(TimeSpan.FromSeconds(10))) return null;
        return value switch
        {
            int number when number > 0 => new BitLockerProtection(number),
            uint number when number > 0 => new BitLockerProtection((int)number),
            _ => null,
        };
    }
}
