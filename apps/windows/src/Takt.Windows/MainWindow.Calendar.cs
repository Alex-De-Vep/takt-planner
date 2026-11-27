using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Windows.Services;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using global::Windows.System;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private (string Id, string Scope)? calendarNotification;
    private (string Workspace, HashSet<string> Retained)? calendarLinkSnapshot;
    private long scheduledBlocksVersion;

    private async Task ReconcileCalendarLinksAsync()
    {
        string scope = library.Workspace;
        var retained = library.Tasks.Select(task => task.Id).ToHashSet(StringComparer.Ordinal);
        // A pending deletion may be rejected, in which case the task can return.
        retained.UnionWith(library.Queue.Where(change => change.Mutation.EntityType == "task" && change.Mutation.Kind == "delete")
            .Select(change => change.Mutation.EntityId));
        if (calendarLinkSnapshot is { } previous && previous.Workspace == scope && retained.SetEquals(previous.Retained))
            return;

        await calendar.DetachMissingTaskLinksAsync(scope, retained);
        calendarLinkSnapshot = (scope, retained);
    }

    private void QueueCalendarNotification(string id, string scope)
    {
        calendarNotification = (id, scope);
        if (ready) _ = Guard(OpenCalendarNotificationAsync);
    }
    private async Task OpenCalendarNotificationAsync()
    {
        if (!ready || calendarNotification is not { } item) return;
        calendarNotification = null;
        if (item.Scope != CalendarReminders.Scope(library.Workspace))
            throw new InvalidOperationException("This calendar reminder belongs to another library. Sign in to that library before opening it.");
        calendarVisible = true; CalendarToggle.IsChecked = true;
        chatVisible = false; UpdateSidePanelVisibility();
        calendarContext = null; await RefreshCalendarContextAsync();
        if (item.Scope != CalendarReminders.Scope(library.Workspace)) throw new InvalidOperationException("The library changed before opening this reminder.");
        Activate();
        await CalendarView.OpenEventAsync(item.Id);
        AdjustLayout();
    }
    private async Task RefreshCalendarRemindersAsync()
    {
        try { await calendarReminders.UpdateAsync(calendar, library.Workspace); }
        catch (Exception)
        {
            ErrorBar.Title = "Calendar reminders unavailable";
            ErrorBar.Message = "Your tasks and notes remain available. Windows could not update the calendar notification schedule.";
            ErrorBar.IsOpen = true;
        }
    }
    private async Task RefreshScheduledBlocksAsync()
    {
        long version = ++scheduledBlocksVersion;
        ScheduledBlocks.Children.Clear();
        ScheduledBlocks.Visibility = Visibility.Collapsed;
        if (showingNotes || draft is not { } task) return;
        string scope = library.Workspace;
        try
        {
            var snapshot = await calendar.ReadAsync(scope);
            if (version != scheduledBlocksVersion || scope != library.Workspace || draft?.Id != task.Id) return;
            var events = snapshot.Events.Where(e => e.TaskId == task.Id).OrderBy(e => e.Start).ToList();
            if (events.Count == 0) return;
            ScheduledBlocks.Children.Add(new TextBlock { Text = "Scheduled time blocks", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            foreach (var entry in events)
            {
                string dates = entry.AllDay ? entry.StartDate!.Value.ToString("d") : entry.Start.ToLocalTime().ToString("g") + " – " + entry.End.ToLocalTime().ToString("t");
                var button = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                    Content = new TextBlock { Text = entry.Title + " · " + dates, TextWrapping = TextWrapping.Wrap } };
                button.Click += async (_, _) => await Guard(async () =>
                {
                    await SaveEditorAsync();
                    if (scope != library.Workspace) throw new InvalidOperationException("This event belongs to another library.");
                    calendarVisible = true; chatVisible = false; UpdateSidePanelVisibility();
                    await RefreshCalendarContextAsync();
                    if (scope != library.Workspace) throw new InvalidOperationException("The library changed before opening this event.");
                    await CalendarView.OpenEventAsync(entry.Id);
                });
                ScheduledBlocks.Children.Add(button);
            }
            ScheduledBlocks.Visibility = Visibility.Visible;
        }
        catch (Exception)
        {
            if (version != scheduledBlocksVersion || scope != library.Workspace || draft?.Id != task.Id) return;
            ScheduledBlocks.Children.Clear(); ScheduledBlocks.Visibility = Visibility.Collapsed;
            ErrorBar.Title = "Scheduled time unavailable"; ErrorBar.Message = "The task is saved. Its local calendar blocks could not be loaded."; ErrorBar.IsOpen = true;
        }
    }
    private async Task RefreshCalendarContextAsync()
    {
        for (int attempt = 0; attempt < 3; ++attempt)
        {
            string scope = library.Workspace;
            string? taskId = showingNotes ? null : draft?.Id;
            string? title = showingNotes ? null : draft?.Text("title");
            string key = scope + "|" + taskId + "|" + title;
            if (calendarContext == key) return;
            await CalendarView.OpenWorkspaceAsync(scope, taskId, title);
            if (scope == library.Workspace) { calendarContext = key; return; }
        }
        calendarContext = null;
        throw new InvalidOperationException("The library changed while opening the calendar. Open it again.");
    }
    private async void CalendarToggle_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (!ready) { CalendarToggle.IsChecked = false; return; }
        calendarVisible = CalendarToggle.IsChecked == true;
        if (calendarVisible) chatVisible = false;
        UpdateSidePanelVisibility();
        if (calendarVisible) { calendarContext = null; await RefreshCalendarContextAsync(); }
        AdjustLayout();
    });
    private async void PlanTime_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        await SaveEditorAsync();
        if (showingNotes || draft is not { } task) throw new InvalidOperationException("Select a task before planning time for it.");
        string scope = library.Workspace;
        calendarVisible = true; CalendarToggle.IsChecked = true;
        chatVisible = false; UpdateSidePanelVisibility();
        await RefreshCalendarContextAsync();
        if (scope != library.Workspace || !library.Tasks.Any(t => t.Id == task.Id)) throw new InvalidOperationException("The task library changed. Select the task again before planning its time.");
        await CalendarView.ScheduleTaskAsync(task.Id, task.Text("title") ?? "Task");
    });
    private async Task OpenCalendarTaskAsync(string workspace, string taskId)
    {
        if (workspace != library.Workspace) throw new InvalidOperationException("This event belongs to another task library.");
        if (!library.Tasks.Any(t => t.Id == taskId)) throw new InvalidOperationException("The linked task is no longer in this library. The calendar event has been kept.");
        await ChangeSectionAsync("all", false);
        if (workspace != library.Workspace) throw new InvalidOperationException("The library changed before opening the linked task.");
        await SelectTaskAsync(taskId);
    }
    private void PanelResize_Started(object sender, DragStartedEventArgs e) => panelWidth = RightPanelColumn.ActualWidth;
    private void PanelResize_Delta(object sender, DragDeltaEventArgs e) => ResizePanel(panelWidth - e.HorizontalChange);
    private void PanelResize_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (VirtualKey.Left or VirtualKey.Right or VirtualKey.Home)) return;
        ResizePanel(e.Key == VirtualKey.Home ? 400 : panelWidth + (e.Key == VirtualKey.Left ? 16 : -16)); e.Handled = true;
    }
    private void ResizePanel(double width)
    {
        double minimum = calendarVisible ? 336 : 300;
        panelWidth = Math.Clamp(width, minimum, Math.Max(minimum, DocumentsAndPanel.ActualWidth - 340));
        RightPanelColumn.Width = new(panelWidth); AdjustLayout();
    }
}
