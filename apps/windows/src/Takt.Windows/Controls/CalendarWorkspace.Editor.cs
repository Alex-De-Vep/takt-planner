using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Globalization;
using Takt.Core.Calendar;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;
using WinRT.Interop;

namespace Takt.Windows.Controls;

public sealed partial class CalendarWorkspace
{
    private static DateTimeOffset PickerDate(DateOnly date) => new(date.ToDateTime(new TimeOnly(12, 0)), TimeZoneInfo.Local.GetUtcOffset(date.ToDateTime(new TimeOnly(12, 0))));
    private static DateOnly Date(CalendarDatePicker picker) => picker.Date is { } value ? DateOnly.FromDateTime(value.DateTime) : throw new InvalidDataException("Choose both dates.");
    private async Task EditAsync(CalendarEntry entry, CalendarEntry? original)
    {
        if (editing) return;
        editing = true;
        string scope = workspace;
        var cancellation = CalendarScopeToken();
        try
        {
            var state = await provider.ReadAsync(scope);
            if (scope != workspace || cancellation.IsCancellationRequested) return;
            var connected = ConnectedDefinitions(scope);
            var external = connected.FirstOrDefault(item => item.Id == entry.CalendarId)?.Connected;
            bool writable = entry.CanEdit && (entry.Connected is null || external?.Calendar.Writable == true);
            bool outlook = external?.Kind == CalendarAccountKind.Outlook;
            TimeZoneInfo tz;
            try { tz = CalendarDates.TimeZone(entry.Zone); } catch (TimeZoneNotFoundException) { tz = TimeZoneInfo.Utc; }
            var start = TimeZoneInfo.ConvertTime(entry.Start, tz); var end = TimeZoneInfo.ConvertTime(entry.End, tz);
            var title = new TextBox { Header = "Title", Text = entry.Title, MaxLength = 4096, IsReadOnly = !writable };
            var calendars = state.Calendars.Concat(connected).Where(item =>
                !writable || entry.Connected is not null ? item.Id == entry.CalendarId :
                item.Writable && (item.Connected is null || original is null && entry.TaskId is null && item.Visible)).ToList();
            var calendar = new ComboBox { Header = "Calendar", ItemsSource = calendars, DisplayMemberPath = "Name",
                SelectedItem = calendars.FirstOrDefault(c => c.Id == entry.CalendarId), HorizontalAlignment = HorizontalAlignment.Stretch,
                IsEnabled = writable && entry.Connected is null };
            var allDay = new ToggleSwitch { Header = "All day", IsOn = entry.AllDay, IsEnabled = writable };
            var first = new CalendarDatePicker { Header = "Start date", Date = PickerDate(entry.StartDate ?? DateOnly.FromDateTime(start.DateTime)), IsEnabled = writable };
            var last = new CalendarDatePicker { Header = "End date (last day included for all-day events)", Date = PickerDate(entry.AllDay ? entry.EndDateExclusive!.Value.AddDays(-1) : DateOnly.FromDateTime(end.DateTime)), IsEnabled = writable };
            var startTime = new TimePicker { Header = "Start time", Time = start.TimeOfDay, IsEnabled = writable };
            var endTime = new TimePicker { Header = "End time", Time = end.TimeOfDay, IsEnabled = writable };
            var zones = TimeZoneInfo.GetSystemTimeZones().Select(z => z.Id).Append(entry.Zone).Distinct().OrderBy(z => z).ToList();
            var zonePicker = new ComboBox { Header = "Time zone", ItemsSource = zones, SelectedItem = entry.Zone, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = writable };
            var times = new StackPanel { Spacing = 8, Visibility = entry.AllDay ? Visibility.Collapsed : Visibility.Visible };
            times.Children.Add(startTime); times.Children.Add(endTime);
            allDay.Toggled += (_, _) => times.Visibility = allDay.IsOn ? Visibility.Collapsed : Visibility.Visible;
            var location = new TextBox { Header = entry.Connected is { CanEditLocation: false } ? "Location (multiple locations in Outlook)" : "Location",
                Text = entry.Location, MaxLength = 4096, IsReadOnly = !writable || entry.Connected is { CanEditLocation: false } };
            var notes = new TextBox { Header = outlook ? "Notes preview (edit in Outlook)" : "Notes", Text = entry.Notes,
                AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100, MaxLength = 262144, IsReadOnly = !writable || outlook };
            var error = new InfoBar { IsOpen = false, IsClosable = false, Severity = InfoBarSeverity.Error };
            ContentDialog? activeEventDialog = null; bool linkedTaskRequested = false;
            var fields = new StackPanel { Spacing = 12, MinWidth = 260, MaxWidth = 440 };
            if (entry.ReadOnlyReason is { } reason) fields.Children.Add(new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap });
            foreach (var field in new UIElement[] { title, calendar, allDay, first, last, times, zonePicker, location, notes }) fields.Children.Add(field);
            fields.Children.Add(new TextBlock { Text = "Calendar events do not change task deadlines or Today, This Week and Month lists.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
            var providerMessage = new TextBlock
            {
                Text = "Changes are saved to the connected calendar. The provider manages alerts and may notify guests.",
                TextWrapping = TextWrapping.Wrap, FontSize = 12
            };
            fields.Children.Add(providerMessage);
            if (entry.TaskId is not null)
            {
                var taskButton = new Button { Content = "Open linked task" };
                taskButton.Click += (_, _) => { linkedTaskRequested = true; activeEventDialog?.Hide(); }; fields.Children.Add(taskButton);
            }
            var alerts = entry.Alarms.ToList(); var alertRows = new StackPanel { Spacing = 6 };
            void RenderAlerts()
            {
                alertRows.Children.Clear();
                var alertZone = tz;
                try { alertZone = CalendarDates.TimeZone(zonePicker.SelectedItem as string ?? entry.Zone); } catch (TimeZoneNotFoundException) { }
                foreach (var alert in alerts.ToList())
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    string label = alert.Absolute is { } absolute ? "At " + TimeZoneInfo.ConvertTime(absolute, alertZone).ToString("g", CultureInfo.CurrentCulture) : alert.OffsetMinutes == 0 ? "At start" : alert.OffsetMinutes < 0 ? $"{-(long)alert.OffsetMinutes!} min before start" : $"{alert.OffsetMinutes} min after start";
                    row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 300 });
                    if (writable) { var remove = new Button { Content = "Remove" }; remove.Click += (_, _) => { alerts.Remove(alert); RenderAlerts(); }; row.Children.Add(remove); }
                    alertRows.Children.Add(row);
                }
            }
            zonePicker.SelectionChanged += (_, _) => RenderAlerts();
            var localAlerts = new StackPanel { Spacing = 6 };
            RenderAlerts();
            localAlerts.Children.Add(new TextBlock { Text = "Alerts", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            localAlerts.Children.Add(alertRows);
            fields.Children.Add(localAlerts);
            if (writable && entry.Connected is null)
            {
                var relative = new NumberBox { Header = "Minutes before start", Minimum = 0, Maximum = 525600, Value = 15, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
                var addRelative = new Button { Content = "Add relative alert" };
                addRelative.Click += (_, _) =>
                {
                    if (!double.IsFinite(relative.Value) || relative.Value != Math.Truncate(relative.Value) || relative.Value < 0 || relative.Value > 525600) return;
                    if (alerts.Count >= 32) { error.Message = "At most 32 alerts are supported."; error.IsOpen = true; return; }
                    alerts.Add(new(Guid.NewGuid().ToString("D"), -(int)relative.Value)); RenderAlerts();
                };
                var absoluteDay = new CalendarDatePicker { Header = "Absolute alert date", Date = PickerDate(DateOnly.FromDateTime(start.DateTime)) };
                var absoluteTime = new TimePicker { Header = "Absolute alert time", Time = start.TimeOfDay };
                var addAbsolute = new Button { Content = "Add absolute alert" };
                addAbsolute.Click += (_, _) =>
                {
                    try
                    {
                        if (alerts.Count >= 32) throw new InvalidDataException("At most 32 alerts are supported.");
                        var absolute = ResolveChosen(Date(absoluteDay).ToDateTime(TimeOnly.FromTimeSpan(absoluteTime.Time)), zonePicker.SelectedItem as string ?? entry.Zone);
                        alerts.Add(new(Guid.NewGuid().ToString("D"), null, absolute)); RenderAlerts();
                    }
                    catch (Exception e) { error.Message = e.Message; error.IsOpen = true; }
                };
                foreach (var field in new UIElement[] { relative, addRelative, absoluteDay, absoluteTime, addAbsolute }) localAlerts.Children.Add(field);
                localAlerts.Children.Add(new TextBlock { Text = "Absolute alerts keep their instant when the event moves. Ambiguous autumn times use the earlier occurrence. Delivery depends on Windows notification settings.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
            }

            void UpdateDestination()
            {
                bool providerManaged = entry.ReadOnly || entry.Connected is not null || (calendar.SelectedItem as CalendarDefinition)?.Connected is not null;
                localAlerts.Visibility = providerManaged ? Visibility.Collapsed : Visibility.Visible;
                providerMessage.Visibility = providerManaged ? Visibility.Visible : Visibility.Collapsed;
                providerMessage.Text = writable
                    ? "Changes are saved to the connected calendar. The provider manages alerts and may notify guests."
                    : "Event alerts are managed by the calendar provider.";
            }
            calendar.SelectionChanged += (_, _) => UpdateDestination();
            UpdateDestination();
            fields.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = original is null ? "New event" : writable ? "Edit event" : "Event", Content = new ScrollViewer { Content = fields, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, PrimaryButtonText = writable ? "Save" : "", SecondaryButtonText = writable && original is not null ? "Delete…" : "", CloseButtonText = writable ? "Cancel" : "Close", DefaultButton = writable ? ContentDialogButton.Primary : ContentDialogButton.Close };
            activeEventDialog = dialog;
            bool deleteConfirmed = false, deleted = false;
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = false;
                try
                {
                    if (scope != workspace || cancellation.IsCancellationRequested)
                        throw new CalendarConflictException("The task library changed. Reopen the calendar in the current library.");
                    var destination = calendar.SelectedItem as CalendarDefinition ?? throw new InvalidDataException("Choose an event calendar.");
                    string eventZone = zonePicker.SelectedItem as string ?? entry.Zone;
                    var firstDay = Date(first); var lastDay = Date(last);
                    DateTimeOffset TimedDate(DateOnly day, TimeSpan time, DateTimeOffset wall, DateTimeOffset instant)
                    {
                        if (entry.Connected is not null && !entry.AllDay && eventZone == entry.Zone &&
                            day == DateOnly.FromDateTime(wall.DateTime) &&
                            time.Hours == wall.Hour && time.Minutes == wall.Minute)
                            return instant;
                        return ResolveChosen(day.ToDateTime(TimeOnly.FromTimeSpan(time)), eventZone);
                    }
                    var begin = allDay.IsOn ? CalendarDates.Resolve(firstDay.ToDateTime(TimeOnly.MinValue), eventZone) :
                        TimedDate(firstDay, startTime.Time, start, entry.Start);
                    var finish = allDay.IsOn ? CalendarDates.Resolve(lastDay.AddDays(1).ToDateTime(TimeOnly.MinValue), eventZone) :
                        TimedDate(lastDay, endTime.Time, end, entry.End);
                    var draft = entry with { Title = original is not null && title.Text == original.Title ? original.Title : title.Text.Trim(),
                        CalendarId = destination.Id, Start = begin, End = finish, Zone = eventZone, AllDay = allDay.IsOn,
                        StartDate = allDay.IsOn ? firstDay : null, EndDateExclusive = allDay.IsOn ? lastDay.AddDays(1) : null,
                        Notes = notes.Text, Location = location.Text, Alerts = destination.Connected is null ? alerts.ToArray() : [] };
                    if (destination.Connected is not null)
                    {
                        await connectedCalendars.SaveAsync(scope, draft, original, cancellation);
                        ResetConnectedAgenda();
                    }
                    else await provider.SaveAsync(scope, draft, original, cancellation);
                    undo = null;
                    CalendarNotice.ActionButton = null;
                }
                catch (Exception e) { args.Cancel = true; error.Severity = InfoBarSeverity.Error; error.Message = e.Message; error.IsOpen = true; }
                finally { dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = true; deferral.Complete(); }
            };
            dialog.SecondaryButtonClick += async (_, args) =>
            {
                if (!deleteConfirmed)
                {
                    args.Cancel = true; deleteConfirmed = true; dialog.SecondaryButtonText = "Confirm delete";
                    error.Severity = InfoBarSeverity.Warning;
                    error.Message = entry.Connected is not null
                        ? "Delete this event from the connected calendar? The provider may notify guests. Press Confirm delete to continue."
                        : "Delete this event and all its alerts? The linked task is kept. Press Confirm delete to continue.";
                    error.IsOpen = true; return;
                }
                var deferral = args.GetDeferral();
                dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = false;
                try
                {
                    if (scope != workspace || cancellation.IsCancellationRequested)
                        throw new CalendarConflictException("The task library changed. Reopen the event.");
                    if (entry.Connected is not null)
                    {
                        await connectedCalendars.DeleteAsync(scope, original!, cancellation);
                        ResetConnectedAgenda();
                    }
                    else await provider.DeleteAsync(scope, original!, cancellation);
                    undo = null; CalendarNotice.ActionButton = null; deleted = true;
                }
                catch (Exception e) { args.Cancel = true; error.Severity = InfoBarSeverity.Error; error.Message = e.Message; error.IsOpen = true; }
                finally { dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = true; deferral.Complete(); }
            };
            var result = await dialog.ShowAsync();
            if (linkedTaskRequested && entry.TaskId is not null) { TaskRequested?.Invoke(this, new(scope, entry.TaskId)); return; }
            if (result == ContentDialogResult.Primary || deleted) Changed?.Invoke(this, EventArgs.Empty);
            if (scope == workspace) await RefreshAsync();
        }
        finally { editing = false; }
    }
    private static DateTimeOffset ResolveChosen(DateTime wall, string zone)
    {
        if (CalendarDates.TimeZone(zone).IsInvalidTime(DateTime.SpecifyKind(wall, DateTimeKind.Unspecified))) throw new InvalidDataException("This time falls in a daylight-saving gap. Choose an existing local time.");
        return CalendarDates.Resolve(wall, zone);
    }
    public async Task ShowSettingsAsync()
    {
        if (editing || workspace.Length == 0) return;
        editing = true;
        string scope = workspace;
        try
        {
            var state = await provider.ReadAsync(scope); if (scope != workspace) return;
            var cancellation = CalendarScopeToken();
            var connected = ConnectedDefinitions(scope);
            var fields = new StackPanel { Spacing = 12, MinWidth = 260, MaxWidth = 440 };
            fields.Children.Add(new TextBlock { Text = "Connect a Google or Outlook account to edit its events here. Subscribe by link to view an external calendar.", TextWrapping = TextWrapping.Wrap });
            var boxes = new Dictionary<string, CheckBox>();
            foreach (var definition in state.Calendars.Concat(connected))
            {
                string suffix = definition.Writable ? "" : definition.Connected is not null ? " (view only)" :
                    definition.Feed is null ? " (snapshot)" : " (subscription)";
                var box = new CheckBox { Content = definition.Name + suffix, IsChecked = definition.Visible };
                boxes[definition.Id] = box;
                fields.Children.Add(box);
            }
            var writable = state.Calendars.Where(c => c.Writable).ToList();
            var defaults = new ComboBox { Header = "Default calendar for new events", ItemsSource = writable, DisplayMemberPath = "Name", SelectedItem = writable.FirstOrDefault(c => c.Id == state.DefaultCalendarId), HorizontalAlignment = HorizontalAlignment.Stretch }; fields.Children.Add(defaults);
            var fileCalendar = new ComboBox { Header = "Calendar for export or removal", ItemsSource = state.Calendars, DisplayMemberPath = "Name", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch }; fields.Children.Add(fileCalendar);
            var action = new ComboBox { Header = "File action after closing settings", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var label in new[] { "None", "Import ICS snapshot…", "Export selected calendar…", "Remove selected calendar…", "Subscribe by link…", "Refresh subscriptions" }) action.Items.Add(label);
            fields.Children.Add(action);
            var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error }; fields.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Calendar settings",
                Content = new ScrollViewer { Content = fields, MaxHeight = 560 }, PrimaryButtonText = "Save",
                SecondaryButtonText = "Calendar accounts…", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    if (scope != workspace || cancellation.IsCancellationRequested) throw new CalendarConflictException("The task library changed. Reopen settings.");
                    var visible = boxes.Where(b => b.Value.IsChecked == true).Select(b => b.Key).ToHashSet(StringComparer.Ordinal);
                    if (connected.Count(item => visible.Contains(item.Id)) > 16)
                        throw new InvalidOperationException("Show at most 16 connected calendars at a time.");
                    if (connected.Length > 0)
                        await connectedCalendars.SetVisibilityAsync(scope, visible, cancellation);
                    await provider.ConfigureAsync(scope, state.Calendars.Where(item => visible.Contains(item.Id)).Select(item => item.Id).ToArray(),
                        (defaults.SelectedItem as CalendarDefinition)?.Id ?? state.DefaultCalendarId, cancellation);
                }
                catch (Exception e) { args.Cancel = true; error.Message = e.Message; error.IsOpen = true; }
                finally { deferral.Complete(); }
            };
            var response = await dialog.ShowAsync();
            if (scope != workspace || cancellation.IsCancellationRequested) return;
            if (response == ContentDialogResult.Secondary)
            {
                await ShowCalendarAccountsAsync(scope);
                return;
            }
            if (response != ContentDialogResult.Primary) return;
            var definitionToUse = fileCalendar.SelectedItem as CalendarDefinition;
            if (action.SelectedIndex == 1)
            {
                var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".ics"); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
                var file = await picker.PickSingleFileAsync();
                if (file is not null)
                {
                    if ((await file.GetBasicPropertiesAsync()).Size > CalendarIcs.MaxBytes) throw new InvalidDataException("Choose an ICS file smaller than 8 MiB.");
                    if (scope != workspace) return;
                    var text = await FileIO.ReadTextAsync(file);
                    if (scope != workspace) return;
                    await provider.ImportAsync(scope, Path.GetFileNameWithoutExtension(file.Name), text);
                }
            }
            else if (action.SelectedIndex == 2 && definitionToUse is not null)
            {
                var picker = new FileSavePicker { SuggestedFileName = "Takt calendar" }; picker.FileTypeChoices.Add("iCalendar", new List<string> { ".ics" }); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
                var file = await picker.PickSaveFileAsync();
                if (file is not null && scope == workspace)
                {
                    var text = await provider.ExportAsync(scope, definitionToUse.Id);
                    if (scope == workspace) await FileIO.WriteTextAsync(file, text);
                }
            }
            else if (action.SelectedIndex == 3 && definitionToUse is not null)
            {
                if (definitionToUse.Writable) throw new InvalidOperationException("The writable local calendar cannot be removed.");
                var confirm = new ContentDialog { XamlRoot = XamlRoot, Title = "Remove calendar?", Content = "Remove this calendar from Takt on this device?", PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
                if (await confirm.ShowAsync() == ContentDialogResult.Primary && scope == workspace) await provider.RemoveSnapshotAsync(scope, definitionToUse.Id);
            }
            else if (action.SelectedIndex == 4) await AddSubscriptionAsync(scope);
            else if (action.SelectedIndex == 5) { await RefreshSubscriptionsAsync(force: true); return; }
            await RefreshAsync(); Changed?.Invoke(this, EventArgs.Empty);
        }
        finally { editing = false; }
    }
}
