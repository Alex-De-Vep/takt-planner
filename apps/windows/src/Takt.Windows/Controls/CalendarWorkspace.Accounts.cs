using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Calendar;
using Takt.Windows.Services;
using global::Windows.System;

namespace Takt.Windows.Controls;

public sealed partial class CalendarWorkspace
{
    private readonly ConnectedCalendars connectedCalendars = new(Preferences.DirectoryPath);
    private readonly DispatcherTimer connectedTimer = new() { Interval = TimeSpan.FromMinutes(2) };
    private CancellationTokenSource? connectedFetch;
    private Task? connectedRequest;
    private string? connectedKey;
    private DateTimeOffset connectedChecked;
    private CalendarEntry[] localInstances = [];
    private CalendarEntry[] connectedInstances = [];

    private CancellationToken CalendarScopeToken() => (subscriptionScope ??= new()).Token;

    private void InitializeConnectedCalendars()
    {
        connectedTimer.Tick += async (_, _) =>
        {
            if (!unloaded && Visibility == Visibility.Visible && snapshot.Calendars.Any(c => c.Connected is not null && c.Visible))
                await Run(RefreshAsync);
        };
        Loaded += (_, _) => connectedTimer.Start();
        Unloaded += (_, _) => connectedTimer.Stop();
    }

    private CalendarDefinition[] ConnectedDefinitions(string scope)
    {
        try { return connectedCalendars.Definitions(scope); }
        catch (Exception)
        {
            Notice("Calendar accounts unavailable", "The saved connections could not be read. Local calendars are still available.", InfoBarSeverity.Warning);
            return [];
        }
    }

    private void ResetConnectedAgenda()
    {
        var previous = connectedFetch;
        connectedFetch = null;
        previous?.Cancel();
        previous?.Dispose();
        connectedRequest = null;
        connectedKey = null;
        connectedInstances = [];
        connectedChecked = default;
    }

    private void UpdateConnectedAgenda(string scope, CalendarDefinition[] definitions,
        IReadOnlyList<(DateOnly First, DateOnly End)> ranges)
    {
        var shown = definitions.Where(definition => definition.Visible).ToArray();
        if (Visibility != Visibility.Visible || shown.Length == 0)
        {
            ResetConnectedAgenda();
            return;
        }

        string key = scope + "|" + string.Join("|", shown.Select(item => item.Id + ":" + item.Writable)) +
            "|" + string.Join("|", ranges.Select(range => $"{range.First.DayNumber}:{range.End.DayNumber}"));
        if (key == connectedKey && (connectedRequest is { IsCompleted: false } ||
            DateTimeOffset.UtcNow - connectedChecked < TimeSpan.FromMinutes(2)))
            return;
        if (connectedKey != key) ResetConnectedAgenda();
        connectedKey = key;
        connectedFetch?.Dispose();
        connectedFetch = CancellationTokenSource.CreateLinkedTokenSource(CalendarScopeToken());
        connectedRequest = FetchConnectedAgendaAsync(scope, shown, ranges, connectedFetch.Token);
    }

    private async Task FetchConnectedAgendaAsync(string scope, CalendarDefinition[] definitions,
        IReadOnlyList<(DateOnly First, DateOnly End)> ranges, CancellationToken cancellation)
    {
        try
        {
            string displayZone = zone;
            var result = await Task.WhenAll(ranges.Select(range =>
                connectedCalendars.QueryAsync(scope, definitions, range.First, range.End, displayZone, cancellation)));
            if (scope != workspace || unloaded || cancellation.IsCancellationRequested || Visibility != Visibility.Visible) return;
            connectedChecked = DateTimeOffset.UtcNow;
            connectedInstances = result.SelectMany(period => period).DistinctBy(item => item.Id).ToArray();
            RenderAvailableEvents();
            var warnings = result.SelectMany(period => period.Warnings).Distinct().Take(8).ToArray();
            if (warnings.Length > 0) Notice("Some connected calendars could not refresh", string.Join("\n", warnings), InfoBarSeverity.Warning);
            else if (CalendarNotice.Title == "Some connected calendars could not refresh") CalendarNotice.IsOpen = false;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception)
        {
            if (scope == workspace && !unloaded && !cancellation.IsCancellationRequested)
                Notice("Connected calendars unavailable", "Open Calendar accounts to refresh your connections.", InfoBarSeverity.Warning);
        }
    }

    private void RenderAvailableEvents()
    {
        instances = localInstances.Concat(connectedInstances).DistinctBy(eventItem => eventItem.Id).ToArray();
        RenderAgenda();
        foreach (var item in dayItems.ToList()) Density(item);
    }

    private async Task ShowCalendarAccountsAsync(string scope)
    {
        var accounts = connectedCalendars.Kinds(scope);
        var panel = new StackPanel { Spacing = 12, MinWidth = 270, MaxWidth = 440 };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Calendar accounts",
            CloseButtonText = "Close", Content = panel
        };
        Func<Task>? action = null;
        foreach (var kind in new[] { CalendarAccountKind.Google, CalendarAccountKind.Outlook })
        {
            string name = ConnectedCalendars.ProviderName(kind);
            bool isConnected = accounts.Contains(kind);
            var connect = new Button { Content = isConnected ? $"Sign in again to {name}…" : $"Connect {name}…" };
            connect.Click += (_, _) => { action = () => SignInCalendarAccountAsync(scope, kind); dialog.Hide(); };
            panel.Children.Add(connect);
            if (isConnected)
            {
                var disconnect = new Button { Content = $"Disconnect {name}…" };
                disconnect.Click += (_, _) => { action = () => DisconnectCalendarAccountAsync(scope, kind); dialog.Hide(); };
                panel.Children.Add(disconnect);
            }
        }
        var refresh = new Button { Content = "Refresh connected calendars", IsEnabled = accounts.Length > 0 };
        refresh.Click += (_, _) => { action = () => RefreshCalendarAccountsAsync(scope); dialog.Hide(); };
        panel.Children.Add(refresh);
        await dialog.ShowAsync();
        if (scope == workspace && action is not null) await action();
    }

    private async Task SignInCalendarAccountAsync(string scope, CalendarAccountKind kind)
    {
        CalendarRegistration? previous;
        try { previous = connectedCalendars.Registration(scope, kind); }
        catch (CalendarAuthorizationExpiredException) { previous = null; }
        bool google = kind == CalendarAccountKind.Google;
        string providerName = ConnectedCalendars.ProviderName(kind);
        var id = new TextBox { Header = "Desktop OAuth client ID", MaxLength = 256, Text = previous?.ClientId ?? "" };
        var secret = new PasswordBox { Header = "Google desktop client secret (if supplied)", MaxLength = 512, Password = previous?.DesktopSecret ?? "" };
        var text = new TextBlock
        {
            Text = google
                ? "Use a Google Cloud Desktop app OAuth client with the Calendar API enabled. Continue to give Takt calendar access in your browser."
                : "Use a Microsoft Entra public client for mobile and desktop applications with http://localhost and delegated Calendars.ReadWrite.",
            TextWrapping = TextWrapping.Wrap
        };
        if (previous is not null) text.Text += " Signing in again replaces this provider’s connection in the open library.";
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        var fields = new StackPanel { Spacing = 12, MinWidth = 270, MaxWidth = 440, Children = { text, id } };
        if (google) fields.Children.Add(secret);
        fields.Children.Add(error);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Connect " + providerName, Content = fields,
            PrimaryButtonText = "Continue in browser", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        using var signIn = CancellationTokenSource.CreateLinkedTokenSource(CalendarScopeToken());
        var cancellation = signIn.Token;
        bool finished = false;
        dialog.CloseButtonClick += (_, _) => signIn.Cancel();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            id.IsEnabled = secret.IsEnabled = false;
            error.IsOpen = false;
            try
            {
                if (scope != workspace) return;
                string? input = google ? secret.Password.Trim() : null;
                await connectedCalendars.ConnectAsync(scope, new(kind, id.Text.Trim(), string.IsNullOrEmpty(input) ? null : input),
                    async address =>
                    {
                        if (!await Launcher.LaunchUriAsync(address))
                            throw new InvalidOperationException("Windows could not open the system browser.");
                    }, cancellation);
                args.Cancel = false;
                finished = true;
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch (Exception failure)
            {
                error.Message = failure is ArgumentException ? failure.Message : ConnectedCalendars.Describe(failure);
                error.IsOpen = true;
            }
            finally
            {
                id.IsEnabled = secret.IsEnabled = true;
                dialog.IsPrimaryButtonEnabled = true;
                deferral.Complete();
            }
        };
        try { await dialog.ShowAsync(); }
        finally { signIn.Cancel(); secret.Password = ""; }
        if (scope == workspace && finished)
        {
            ResetConnectedAgenda();
            await RefreshAsync();
        }
    }

    private async Task DisconnectCalendarAccountAsync(string scope, CalendarAccountKind kind)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Disconnect " + ConnectedCalendars.ProviderName(kind) + "?",
            Content = "This removes the connection from this Takt library. Its events stay with the provider.",
            PrimaryButtonText = "Disconnect", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || scope != workspace) return;
        await connectedCalendars.DisconnectAsync(scope, kind, CalendarScopeToken());
        ResetConnectedAgenda();
        await RefreshAsync();
    }

    private async Task RefreshCalendarAccountsAsync(string scope)
    {
        var cancellation = CalendarScopeToken();
        var warnings = await connectedCalendars.RefreshCalendarListsAsync(scope, cancellation);
        if (scope != workspace || cancellation.IsCancellationRequested) return;
        ResetConnectedAgenda();
        await RefreshAsync();
        if (warnings.Length > 0) Notice("Calendar accounts could not refresh", string.Join("\n", warnings), InfoBarSeverity.Warning);
    }
}
