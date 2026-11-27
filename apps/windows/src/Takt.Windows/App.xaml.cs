using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Takt.Windows;

public partial class App : Application
{
    private Window? window;
    private AppInstance? instance;
    public App() => InitializeComponent();
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        instance = AppInstance.FindOrRegisterForKey("takt-windows-tasks");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Exit(); return;
        }
        // One process owns the SQLite library and refresh-token rotation.
        instance.Activated += (_, _) => window?.DispatcherQueue.TryEnqueue(() => window.Activate());
        window = new MainWindow(); window.Activate();
    }
}
