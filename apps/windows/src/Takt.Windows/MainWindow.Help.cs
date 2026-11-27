using Microsoft.UI.Xaml;
using Takt.Windows.Controls;
using Takt.Windows.Services;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private async void Guide_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (!ready) return;
        await SaveEditorAsync();
        await WindowsHelp.ShowAsync(Root.XamlRoot);
    });
    private async void Welcome_Click(object sender, RoutedEventArgs e) => await Guard(ShowWelcomeAsync);
    private async Task ShowWelcomeAsync()
    {
        if (!ready || closing) return;
        await SaveEditorAsync();
        var welcome = new WelcomeDialog { XamlRoot = Root.XamlRoot };
        await welcome.ShowAsync();
        if (closing) return;
        preferences = preferences with { WelcomeSeen = true };
        try { preferences.Save(); }
        catch (Exception)
        {
            ErrorBar.Title = "Welcome preference not saved";
            ErrorBar.Message = "You can continue working. The welcome screen may appear again next time.";
            ErrorBar.IsOpen = true;
        }
        switch (welcome.Destination)
        {
            case "task": await ChangeSectionAsync("inbox", false); break;
            case "note": await ChangeSectionAsync("notes:all", true); break;
            case "calendar":
                calendarVisible = true; chatVisible = false; UpdateSidePanelVisibility();
                await RefreshCalendarContextAsync(); break;
            case "chat":
                chatVisible = true; calendarVisible = false; UpdateSidePanelVisibility();
                await RefreshChatWorkspaceAsync(); break;
        }
    }
}
