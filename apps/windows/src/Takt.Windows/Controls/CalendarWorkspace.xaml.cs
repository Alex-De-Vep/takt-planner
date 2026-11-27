using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using System.Globalization;
using System.Text.Json;
using Takt.Core.Calendar;
using global::Windows.ApplicationModel.DataTransfer;

namespace Takt.Windows.Controls;

public sealed class CalendarTaskRequestedEventArgs(string workspace, string taskId) : EventArgs
{
    public string Workspace { get; } = workspace;
    public string TaskId { get; } = taskId;
}
public sealed partial class CalendarWorkspace : UserControl
{
    private const string DragFormat = "application/x-takt-calendar-move";
    private ICalendarProvider provider = null!;
    private Window owner = null!;
    private string workspace = "", zone = TimeZoneInfo.Local.Id;
    private string? taskId, taskTitle;
    private DateOnly selected = DateOnly.FromDateTime(DateTime.Today);
    private CalendarAgendaMode mode = CalendarAgendaMode.Day;
    private CalendarSnapshot snapshot = CalendarSnapshot.Empty;
    private IReadOnlyList<CalendarEntry> instances = [];
    private bool loading, editing, unloaded;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly HashSet<CalendarViewDayItem> dayItems = [];
    private readonly HashSet<DateOnly> densityDates = [];
    private readonly DispatcherTimer densityRefresh = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private CalendarMove? undo;
    private (string Scope, string Token, CalendarEntry Entry, DateOnly Source)? dragging;
    public event EventHandler<CalendarTaskRequestedEventArgs>? TaskRequested;
    public event EventHandler? Changed;
    public CalendarWorkspace()
    {
        InitializeComponent();
        InitializeSubscriptions();
        InitializeConnectedCalendars();
        Month.FirstDayOfWeek = (global::Windows.Globalization.DayOfWeek)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
        densityRefresh.Tick += async (_, _) => { densityRefresh.Stop(); if (!unloaded) await Run(RefreshAsync); };
        Loaded += (_, _) => unloaded = false;
        Unloaded += (_, _) => { unloaded = true; densityRefresh.Stop(); };
    }
    public void Initialize(ICalendarProvider calendarProvider, Window window) { provider = calendarProvider; owner = window; }
    public async Task OpenWorkspaceAsync(string nextWorkspace, string? selectedTaskId = null, string? selectedTaskTitle = null)
    {
        bool changed = workspace != nextWorkspace;
        workspace = nextWorkspace; taskId = selectedTaskId; taskTitle = selectedTaskTitle;
        ForTaskButton.IsEnabled = taskId is not null;
        if (changed)
        {
            ResetSubscriptionScope();
            selected = DateOnly.FromDateTime(DateTime.Today); densityDates.Clear(); undo = null; dragging = null; CalendarNotice.IsOpen = false;
            SetMonthSelection();
        }
        await RefreshAsync();
        _ = RefreshSubscriptionsAsync(force: false);
    }
    public async Task ScheduleTaskAsync(string selectedTaskId, string title)
    {
        if (workspace.Length == 0) return;
        await EditAsync(CalendarEntry.Create(snapshot.DefaultCalendarId, title, selected, selectedTaskId), null);
    }
    public async Task OpenEventAsync(string eventId)
    {
        string scope = workspace; var entry = await provider.GetEventAsync(scope, eventId);
        if (scope != workspace) return;
        if (entry is null) { Notice("Event unavailable", "The event or imported snapshot no longer exists.", InfoBarSeverity.Warning); return; }
        selected = entry.AllDay ? entry.StartDate!.Value : CalendarDates.LocalDate(entry.Start, zone); SetMonthSelection(); await RefreshAsync();
        if (scope == workspace) await EditAsync(entry, entry);
    }
    public Task RefreshAsync() => RefreshCoreAsync();
    private async Task RefreshCoreAsync()
    {
        if (workspace.Length == 0 || unloaded) return;
        await refreshGate.WaitAsync();
        try
        {
            string scope = workspace;
            var data = await provider.ReadAsync(scope);
            var monthStart = new DateOnly(selected.Year, selected.Month, 1);
            // Whole selected month, overflow days and the full week/3-day agenda.
            var first = monthStart.AddDays(-7); var end = monthStart.AddMonths(1).AddDays(14);
            var events = await provider.QueryAsync(scope, first, end, zone);
            var all = events.ToList(); var warnings = events.Warnings.ToList();
            var ranges = new List<(DateOnly First, DateOnly End)> { (first, end) };
            var covered = new HashSet<DateOnly>();
            for (var d = first; d < end; d = d.AddDays(1)) covered.Add(d);
            // Native month arrows do not change SelectedDates. Query newly realized
            // months too, so density marks follow browsing without moving the agenda.
            var extraMonths = dayItems.Select(i => DateOnly.FromDateTime(i.Date.DateTime)).Where(d => !covered.Contains(d)).Select(d => new DateOnly(d.Year, d.Month, 1)).Distinct().ToList();
            foreach (var month in extraMonths)
            {
                var extra = await provider.QueryAsync(scope, month, month.AddMonths(1), zone);
                all.AddRange(extra); warnings.AddRange(extra.Warnings);
                ranges.Add((month, month.AddMonths(1)));
                for (var d = month; d < month.AddMonths(1); d = d.AddDays(1)) covered.Add(d);
            }
            if (scope != workspace || unloaded) return;
            var connected = ConnectedDefinitions(scope);
            snapshot = data with { Calendars = data.Calendars.Concat(connected).ToArray() };
            localInstances = all.ToArray();
            densityDates.Clear(); densityDates.UnionWith(covered);
            UpdateConnectedAgenda(scope, connected, ranges);
            RenderAvailableEvents();
            if (warnings.Count > 0) Notice("Snapshot unavailable", string.Join("\n", warnings.Distinct()) + " Manage imported files in Calendar settings.", InfoBarSeverity.Warning);
        }
        finally { refreshGate.Release(); }
    }
    private void SetMonthSelection()
    {
        loading = true;
        try { var date = CalendarDates.Resolve(selected.ToDateTime(TimeOnly.MinValue), zone); Month.SelectedDates.Clear(); Month.SelectedDates.Add(date); Month.SetDisplayDate(date); }
        finally { loading = false; }
    }
    private DateOnly PeriodStart => CalendarDates.PeriodStart(selected, mode, CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek);
    private void RenderAgenda()
    {
        var first = PeriodStart; int count = (int)mode;
        PeriodHeading.Text = count == 1 ? first.ToString("dddd, d MMMM", CultureInfo.CurrentCulture) : $"{first.ToString("d MMM", CultureInfo.CurrentCulture)} – {first.AddDays(count - 1).ToString("d MMM", CultureInfo.CurrentCulture)}";
        ColumnsToggle.IsEnabled = count > 1;
        bool columns = ColumnsToggle.IsChecked == true && count > 1;
        Agenda.Orientation = columns ? Orientation.Horizontal : Orientation.Vertical; Agenda.Children.Clear();
        for (int offset = 0; offset < count; ++offset)
        {
            var day = first.AddDays(offset);
            var contents = new StackPanel { Spacing = 6 };
            if (count > 1) contents.Children.Add(new TextBlock { Text = day.ToString("ddd, d MMM", CultureInfo.CurrentCulture), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            var events = instances.Where(e => CalendarDates.OccursOn(e, day, zone)).OrderByDescending(e => e.AllDay).ThenBy(e => e.Start).ToList();
            if (events.Count == 0) contents.Children.Add(new TextBlock { Text = "No events", Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
            foreach (var entry in events) contents.Children.Add(EventButton(entry, day));
            var target = new Border { Child = contents, Padding = new Thickness(4, 8, 4, 12), MinHeight = 96, AllowDrop = count > 1, MinWidth = columns ? 220 : 0 };
            if (columns) target.Width = 240;
            target.DragOver += (_, args) => { if (dragging is { } drag && drag.Scope == workspace && args.DataView.Contains(DragFormat)) args.AcceptedOperation = DataPackageOperation.Move; };
            target.Drop += async (_, args) =>
            {
                if (dragging is not { } drag || drag.Scope != workspace || !args.DataView.Contains(DragFormat)) return;
                var value = await args.DataView.GetDataAsync(DragFormat) as string;
                if (value != drag.Token || drag.Scope != workspace) return;
                args.Handled = true;
                await Run(async () =>
                {
                    var moved = await provider.MoveAsync(drag.Scope, drag.Entry, drag.Source, day, zone);
                    if (drag.Scope != workspace) return;
                    undo = moved;
                    await RefreshAsync(); Changed?.Invoke(this, EventArgs.Empty);
                    var button = new Button { Content = "Undo move" }; button.Click += async (_, _) => await Run(UndoAsync);
                    CalendarNotice.ActionButton = button; Notice("Event moved", "The event's duration and absolute alerts were preserved.", InfoBarSeverity.Success);
                });
            };
            Agenda.Children.Add(target);
        }
    }
    private FrameworkElement EventButton(CalendarEntry entry, DateOnly day)
    {
        string cardScope = workspace;
        var contents = new StackPanel { Spacing = 3 };
        contents.Children.Add(new TextBlock { Text = entry.Title, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var start = TimeZoneInfo.ConvertTime(entry.Start, CalendarDates.TimeZone(zone)); var end = TimeZoneInfo.ConvertTime(entry.End, CalendarDates.TimeZone(zone));
        string time = entry.AllDay ? "All day" : $"{start.ToString("t", CultureInfo.CurrentCulture)} – {end.ToString("t", CultureInfo.CurrentCulture)}";
        var calendar = snapshot.Calendars.FirstOrDefault(c => c.Id == entry.CalendarId)?.Name ?? "Calendar";
        contents.Children.Add(new TextBlock { Text = time + " · " + calendar, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        if (entry.Recurring) contents.Children.Add(new TextBlock { Text = "Recurring · View only", FontSize = 12 });
        else if (entry.ReadOnly) contents.Children.Add(new TextBlock { Text = entry.Connected is not null ? "View only" :
            snapshot.Calendars.Any(item => item.Id == entry.CalendarId && item.Feed is not null)
                ? "Subscription · View only" : "Imported snapshot · View only", FontSize = 12 });
        var button = new Button { Content = contents, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, CanDrag = entry.CanEdit && entry.Connected is null && mode != CalendarAgendaMode.Day };
        AutomationProperties.SetName(button, entry.Title + ", " + time);
        button.Click += async (_, _) => await Run(async () =>
        {
            if (cardScope != workspace || editing) return;
            var cancellation = CalendarScopeToken();
            var latest = entry.Connected is null ? await provider.GetEventAsync(cardScope, entry.Id, cancellation) :
                await connectedCalendars.GetAsync(cardScope, entry, cancellation);
            if (cardScope != workspace || cancellation.IsCancellationRequested) return;
            if (latest is null) throw new CalendarConflictException("This event was deleted.");
            await EditAsync(latest, latest);
        });
        button.DragStarting += (_, args) =>
        {
            if (cardScope != workspace || !entry.CanEdit || entry.Connected is not null || mode == CalendarAgendaMode.Day) { args.Cancel = true; return; }
            var token = Guid.NewGuid().ToString("N"); dragging = (workspace, token, entry, day); args.Data.SetData(DragFormat, token); args.Data.RequestedOperation = DataPackageOperation.Move;
        };
        button.DropCompleted += (_, _) => dragging = null;
        var card = new StackPanel { Spacing = 2 }; card.Children.Add(button);
        if (entry.TaskId is not null)
        {
            var linked = new HyperlinkButton { Content = "Open linked task", Padding = new Thickness(8, 2, 8, 2), HorizontalAlignment = HorizontalAlignment.Left };
            linked.Click += (_, _) => { if (cardScope == workspace) TaskRequested?.Invoke(this, new(cardScope, entry.TaskId)); };
            card.Children.Add(linked);
        }
        return card;
    }
    private async Task UndoAsync()
    {
        if (undo is null) return;
        string scope = workspace; var request = undo;
        await provider.UndoMoveAsync(scope, request);
        if (scope != workspace) return;
        undo = null; CalendarNotice.ActionButton = null; CalendarNotice.IsOpen = false;
        await RefreshAsync(); Changed?.Invoke(this, EventArgs.Empty);
    }
    private void Density(CalendarViewDayItem item)
    {
        var date = DateOnly.FromDateTime(item.Date.DateTime); int count = instances.Count(e => CalendarDates.OccursOn(e, date, zone));
        var accent = (global::Windows.UI.Color)Application.Current.Resources["SystemAccentColor"];
        item.SetDensityColors(Enumerable.Repeat(accent, Math.Min(count, 5)).ToList());
    }
    private void Month_DayItemChanging(CalendarView sender, CalendarViewDayItemChangingEventArgs args)
    {
        if (args.InRecycleQueue) { dayItems.Remove(args.Item); return; }
        dayItems.Add(args.Item); Density(args.Item);
        if (workspace.Length > 0 && !densityDates.Contains(DateOnly.FromDateTime(args.Item.Date.DateTime))) { densityRefresh.Stop(); densityRefresh.Start(); }
    }
    private async void Month_SelectedDatesChanged(CalendarView sender, CalendarViewSelectedDatesChangedEventArgs args)
    {
        if (loading || sender.SelectedDates.Count == 0 || workspace.Length == 0) return;
        selected = DateOnly.FromDateTime(sender.SelectedDates[0].DateTime); await Run(RefreshAsync);
    }
    private async void Mode_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (Agenda is null || ModePicker is null) return;
        mode = ModePicker.SelectedIndex switch { 1 => CalendarAgendaMode.ThreeDays, 2 => CalendarAgendaMode.Week, _ => CalendarAgendaMode.Day }; await Run(RefreshAsync);
    }
    private void Columns_Click(object sender, RoutedEventArgs args) => RenderAgenda();
    private async void Previous_Click(object sender, RoutedEventArgs args) { selected = selected.AddDays(-(int)mode); SetMonthSelection(); await Run(RefreshAsync); }
    private async void Next_Click(object sender, RoutedEventArgs args) { selected = selected.AddDays((int)mode); SetMonthSelection(); await Run(RefreshAsync); }
    private async void Today_Click(object sender, RoutedEventArgs args) { selected = DateOnly.FromDateTime(DateTime.Today); SetMonthSelection(); await Run(RefreshAsync); }
    private async void NewEvent_Click(object sender, RoutedEventArgs args) => await Run(() => EditAsync(CalendarEntry.Create(snapshot.DefaultCalendarId, "", selected), null));
    private async void ForTask_Click(object sender, RoutedEventArgs args) { if (taskId is not null) await Run(() => ScheduleTaskAsync(taskId, taskTitle ?? "Task")); }
    private async void Settings_Click(object sender, RoutedEventArgs args) => await Run(ShowSettingsAsync);
    private void Notice(string title, string message, InfoBarSeverity severity = InfoBarSeverity.Error)
    {
        if (title != "Event moved") CalendarNotice.ActionButton = null;
        CalendarNotice.Title = title; CalendarNotice.Message = message; CalendarNotice.Severity = severity; CalendarNotice.IsOpen = true;
    }
    private async Task Run(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (!unloaded) Notice("Calendar", e.Message); }
    }
}
