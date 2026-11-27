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
        if (editing) return; editing = true; string scope = workspace;
        try
        {
            var state = await provider.ReadAsync(scope);
            if (scope != workspace) return;
            bool writable = entry.CanEdit;
            TimeZoneInfo tz;
            try { tz = CalendarDates.TimeZone(entry.Zone); } catch (TimeZoneNotFoundException) { tz = TimeZoneInfo.Utc; }
            var start = TimeZoneInfo.ConvertTime(entry.Start, tz); var end = TimeZoneInfo.ConvertTime(entry.End, tz);
            var title = new TextBox { Header = "Title", Text = entry.Title, MaxLength = 4096, IsReadOnly = !writable };
            var calendars = state.Calendars.Where(c => writable ? c.Writable : c.Id == entry.CalendarId).ToList();
            var calendar = new ComboBox { Header = "Calendar", ItemsSource = calendars, DisplayMemberPath = "Name", SelectedItem = calendars.FirstOrDefault(c => c.Id == entry.CalendarId), HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = writable };
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
            var location = new TextBox { Header = "Location", Text = entry.Location, MaxLength = 4096, IsReadOnly = !writable };
            var notes = new TextBox { Header = "Notes", Text = entry.Notes, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100, MaxLength = 262144, IsReadOnly = !writable };
            var error = new InfoBar { IsOpen = false, IsClosable = false, Severity = InfoBarSeverity.Error };
            ContentDialog? activeEventDialog = null; bool linkedTaskRequested = false;
            var fields = new StackPanel { Spacing = 12, MinWidth = 260, MaxWidth = 440 };
            if (entry.ReadOnlyReason is { } reason) fields.Children.Add(new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap });
            foreach (var field in new UIElement[] { title, calendar, allDay, first, last, times, zonePicker, location, notes }) fields.Children.Add(field);
            fields.Children.Add(new TextBlock { Text = "Calendar events do not change task deadlines or Today, This Week and Month lists.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
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
            RenderAlerts(); fields.Children.Add(new TextBlock { Text = "Alerts", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); fields.Children.Add(alertRows);
            if (writable)
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
                foreach (var field in new UIElement[] { relative, addRelative, absoluteDay, absoluteTime, addAbsolute }) fields.Children.Add(field);
                fields.Children.Add(new TextBlock { Text = "Absolute alerts keep their instant when the event moves. Ambiguous autumn times use the earlier occurrence. Delivery depends on Windows notification settings.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
            }
            else if (entry.ReadOnly) fields.Children.Add(new TextBlock { Text = "Event alerts are managed by the external calendar provider.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
            fields.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = original is null ? "New event" : writable ? "Edit event" : "Event", Content = new ScrollViewer { Content = fields, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, PrimaryButtonText = writable ? "Save" : "", SecondaryButtonText = writable && original is not null ? "Delete…" : "", CloseButtonText = writable ? "Cancel" : "Close", DefaultButton = writable ? ContentDialogButton.Primary : ContentDialogButton.Close };
            activeEventDialog = dialog;
            bool deleteConfirmed = false, deleted = false;
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    if (scope != workspace) throw new CalendarConflictException("The task library changed. Reopen the calendar in the current library.");
                    string eventZone = zonePicker.SelectedItem as string ?? entry.Zone;
                    var firstDay = Date(first); var lastDay = Date(last);
                    var begin = allDay.IsOn ? CalendarDates.Resolve(firstDay.ToDateTime(TimeOnly.MinValue), eventZone) : ResolveChosen(firstDay.ToDateTime(TimeOnly.FromTimeSpan(startTime.Time)), eventZone);
                    var finish = allDay.IsOn ? CalendarDates.Resolve(lastDay.AddDays(1).ToDateTime(TimeOnly.MinValue), eventZone) : ResolveChosen(lastDay.ToDateTime(TimeOnly.FromTimeSpan(endTime.Time)), eventZone);
                    var draft = entry with { Title = title.Text.Trim(), CalendarId = (calendar.SelectedItem as CalendarDefinition)?.Id ?? "", Start = begin, End = finish, Zone = eventZone, AllDay = allDay.IsOn, StartDate = allDay.IsOn ? firstDay : null, EndDateExclusive = allDay.IsOn ? lastDay.AddDays(1) : null, Notes = notes.Text, Location = location.Text, Alerts = alerts.ToArray() };
                    _ = await provider.SaveAsync(scope, draft, original); undo = null; CalendarNotice.ActionButton = null;
                }
                catch (Exception e) { args.Cancel = true; error.Message = e.Message; error.IsOpen = true; }
                finally { deferral.Complete(); }
            };
            dialog.SecondaryButtonClick += async (_, args) =>
            {
                if (!deleteConfirmed)
                {
                    args.Cancel = true; deleteConfirmed = true; dialog.SecondaryButtonText = "Confirm delete";
                    error.Severity = InfoBarSeverity.Warning; error.Message = "Delete this event and all its alerts? The linked task is kept. Press Confirm delete to continue."; error.IsOpen = true; return;
                }
                var deferral = args.GetDeferral();
                try
                {
                    if (scope != workspace) throw new CalendarConflictException("The task library changed. Reopen the event.");
                    await provider.DeleteAsync(scope, original!); undo = null; CalendarNotice.ActionButton = null; deleted = true;
                }
                catch (Exception e) { args.Cancel = true; error.Severity = InfoBarSeverity.Error; error.Message = e.Message; error.IsOpen = true; }
                finally { deferral.Complete(); }
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
            var fields = new StackPanel { Spacing = 12, MinWidth = 260, MaxWidth = 440 };
            fields.Children.Add(new TextBlock { Text = "Local events and task links stay on this Windows device. Subscribe to a calendar for automatic updates or import a one-time ICS copy.", TextWrapping = TextWrapping.Wrap });
            var boxes = new Dictionary<string, CheckBox>();
            foreach (var definition in state.Calendars)
            {
                var box = new CheckBox { Content = definition.Name + (definition.Writable ? "" : definition.Feed is null ? " (snapshot)" : " (subscription)"), IsChecked = definition.Visible }; boxes[definition.Id] = box; fields.Children.Add(box);
            }
            var writable = state.Calendars.Where(c => c.Writable).ToList();
            var defaults = new ComboBox { Header = "Default calendar for new events", ItemsSource = writable, DisplayMemberPath = "Name", SelectedItem = writable.FirstOrDefault(c => c.Id == state.DefaultCalendarId), HorizontalAlignment = HorizontalAlignment.Stretch }; fields.Children.Add(defaults);
            var fileCalendar = new ComboBox { Header = "Calendar for export or removal", ItemsSource = state.Calendars, DisplayMemberPath = "Name", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch }; fields.Children.Add(fileCalendar);
            var action = new ComboBox { Header = "File action after closing settings", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var label in new[] { "None", "Import ICS snapshot…", "Export selected calendar…", "Remove selected calendar…", "Subscribe by link…", "Refresh subscriptions" }) action.Items.Add(label);
            fields.Children.Add(action);
            var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error }; fields.Children.Add(error);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Calendar settings", Content = new ScrollViewer { Content = fields }, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
            dialog.PrimaryButtonClick += async (_, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    if (scope != workspace) throw new CalendarConflictException("The task library changed. Reopen settings.");
                    await provider.ConfigureAsync(scope, boxes.Where(b => b.Value.IsChecked == true).Select(b => b.Key).ToArray(), (defaults.SelectedItem as CalendarDefinition)?.Id ?? state.DefaultCalendarId);
                }
                catch (Exception e) { args.Cancel = true; error.Message = e.Message; error.IsOpen = true; }
                finally { deferral.Complete(); }
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (scope != workspace) return;
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
