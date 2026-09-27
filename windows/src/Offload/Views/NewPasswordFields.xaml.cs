using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

public partial class NewPasswordFields : UserControl
{
    public NewPasswordFields() => InitializeComponent();

    public string Password => First.Password;

    public bool IsAcceptable => PasswordStrength.Evaluate(First.Password).IsAcceptable && First.Password == Second.Password;

    /// <summary>Пароль стал годным или перестал — кнопка «Создать» у того, кто вставил поля, это слушает.</summary>
    public event EventHandler? AcceptabilityChanged;

    void Changed(object sender, RoutedEventArgs e)
    {
        Strength.Password = First.Password;
        Mismatch.Visibility = Second.Password.Length > 0 && Second.Password != First.Password ? Visibility.Visible : Visibility.Collapsed;
        AcceptabilityChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        First.Clear();
        Second.Clear();
    }
}
