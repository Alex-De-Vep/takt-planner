using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Calendar;
using Takt.Windows.Services;

namespace Takt.Windows.Controls;

public sealed partial class CalendarWorkspace
{
    private readonly CalendarFeedClient feedClient = new();
    private readonly WindowsVault feedVault = new();
    private readonly SemaphoreSlim feedRefresh = new(1, 1);
    private readonly DispatcherTimer subscriptionTimer = new() { Interval = TimeSpan.FromMinutes(15) };
    private CancellationTokenSource? subscriptionScope;
    private DateTimeOffset lastAutomaticCheck;

    private void InitializeSubscriptions()
    {
        subscriptionTimer.Tick += async (_, _) => await RefreshSubscriptionsAsync(force: false);
        Loaded += (_, _) => subscriptionTimer.Start();
        Unloaded += (_, _) =>
        {
            subscriptionTimer.Stop();
            ResetSubscriptionScope();
        };
    }

    public void ResetSubscriptionScope()
    {
        var previous = subscriptionScope;
        subscriptionScope = null;
        previous?.Cancel();
        previous?.Dispose();
        lastAutomaticCheck = default;
        ResetConnectedAgenda();
    }

    private static string FeedScope(string workspace, string id) => $"calendar-feed:{workspace}:{id}";

    private async Task AddSubscriptionAsync(string scope)
    {
        var name = new TextBox { Header = "Name", MaxLength = 256 };
        var address = new PasswordBox { Header = "Calendar link", MaxLength = 8192 };
        var status = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        var text = new TextBlock
        {
            Text = "Paste an iCal subscription link from your calendar provider. Treat private links like passwords.",
            TextWrapping = TextWrapping.Wrap
        };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Subscribe to a calendar",
            Content = new StackPanel { Spacing = 12, Children = { text, name, address, status } },
            PrimaryButtonText = "Subscribe",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        var token = (subscriptionScope ??= new()).Token;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            name.IsEnabled = address.IsEnabled = false;
            status.IsOpen = false;
            try
            {
                if (scope != workspace) return;
                string calendarName = name.Text.Trim();
                if (calendarName.Length == 0) throw new ArgumentException("Enter a calendar name.");
                Uri uri = CalendarFeedClient.ParseAddress(address.Password);
                string id = Guid.NewGuid().ToString("D");
                var response = await feedClient.FetchAsync(uri, null, token);
                if (scope != workspace || token.IsCancellationRequested) return;
                var feed = new CalendarFeed(feedVault.Seal(FeedScope(scope, id), uri.AbsoluteUri), DateTimeOffset.UtcNow, response.ETag);
                await provider.SubscribeAsync(scope, id, calendarName,
                    response.CalendarText ?? throw new InvalidDataException("The provider did not return a calendar."), feed, token);
                args.Cancel = false;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception error)
            {
                status.Message = error is ArgumentException or InvalidOperationException or InvalidDataException or TimeoutException
                    ? error.Message : "The subscription could not be saved.";
                status.IsOpen = true;
            }
            finally
            {
                name.IsEnabled = address.IsEnabled = true;
                dialog.IsPrimaryButtonEnabled = true;
                deferral.Complete();
            }
        };
        try { await dialog.ShowAsync(); }
        finally { address.Password = ""; }
    }

    public async Task RefreshSubscriptionsAsync(bool force)
    {
        if (workspace.Length == 0 || unloaded || !force && Visibility != Visibility.Visible ||
            !await feedRefresh.WaitAsync(0)) return;
        string scope = workspace;
        var cancellation = (subscriptionScope ??= new()).Token;
        try
        {
            var now = DateTimeOffset.UtcNow;
            if (!force && now - lastAutomaticCheck < TimeSpan.FromMinutes(14)) return;
            lastAutomaticCheck = now;
            var state = await provider.ReadAsync(scope, cancellation);
            bool changed = false;
            int failed = 0, attempted = 0;
            foreach (var calendar in state.Calendars)
            {
                if (scope != workspace || cancellation.IsCancellationRequested) return;
                if (calendar.Feed is not { } feed || !force && now - feed.CheckedAt < TimeSpan.FromMinutes(15)) continue;
                attempted++;
                try
                {
                    var uri = CalendarFeedClient.ParseAddress(feedVault.Open(FeedScope(scope, calendar.Id), feed.ProtectedAddress));
                    var response = await feedClient.FetchAsync(uri, feed.ETag, cancellation);
                    if (scope != workspace || cancellation.IsCancellationRequested) return;
                    changed |= await provider.UpdateSubscriptionAsync(scope, calendar, response.CalendarText,
                        feed with { CheckedAt = DateTimeOffset.UtcNow, ETag = response.ETag }, cancellation);
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
                catch (Exception) { failed++; }
            }
            if (scope != workspace || cancellation.IsCancellationRequested) return;
            if (changed) await RefreshAsync();
            if (failed > 0)
                Notice("Subscriptions could not refresh", "Previous calendar contents are still available. Check the connection or replace an expired link.", InfoBarSeverity.Warning);
            else if (force)
                Notice("External calendars", attempted > 0 ? "Subscriptions are up to date." : "Add a subscription from Calendar settings.", InfoBarSeverity.Success);
            else if (attempted > 0 && CalendarNotice.Title == "Subscriptions could not refresh")
                CalendarNotice.IsOpen = false;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception)
        {
            if (force && scope == workspace) Notice("Subscriptions unavailable", "Takt could not read the local subscription settings.");
        }
        finally { feedRefresh.Release(); }
    }
}
