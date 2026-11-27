using CommunityToolkit.WinUI.Notifications;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Notes;
using Takt.Core.Calendar;
using Takt.Windows.Controls;
using Takt.Core.Storage;
using Takt.Core.Sync;
using Takt.Windows.Services;
using Takt.Windows.ViewModels;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;
using global::Windows.System;
using WinRT.Interop;

namespace Takt.Windows;

public sealed partial class MainWindow : Window
{
    public ObservableCollection<TaskRow> ActiveTasks { get; } = [];
    public ObservableCollection<TaskRow> CompletedTasks { get; } = [];
    public ObservableCollection<ChecklistRow> ChecklistItems { get; } = [];
    private readonly PlannerStore store;
    private readonly NoteStore notes;
    private readonly LocalCalendarProvider calendar;
    private bool calendarVisible;
    private double panelWidth = 400;
    private string? calendarContext;
    private NotesState noteState = NotesState.Empty;
    private bool showingNotes, notesReady;
    private readonly HttpClient http = ApiClient.CreateHttpClient();
    private readonly CloudSync sync;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim reloadGate = new(1, 1);
    private readonly SemaphoreSlim navigationGate = new(1, 1);
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly WindowsReminders reminders = new();
    private readonly CalendarReminders calendarReminders = new();
    private Preferences preferences = new();
    private Library library = Library.Empty;
    private Entity? draft;
    private string? draftWorkspace, draftLocation;
    private bool draftNeedsRecovery;
    private string section = "inbox";
    private bool rendering, ready, syncing, navigating, editing, closing;
    private double resizeWidth;
    private string folderSignature = "uninitialized";
    private DateOnly currentDay = DateOnly.FromDateTime(DateTime.Now);
    private (string Task, string Scope)? notification;
    private const string DragFormat = "application/x-takt-task";

    public MainWindow()
    {
        InitializeComponent(); InitializeTaskAutosave(); InitializeLiveSync();
        ExtendsContentIntoTitleBar = true; SetTitleBar(TitleDragRegion);
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1280, 820));
        store = new PlannerStore(Path.Combine(Preferences.DirectoryPath, "tasks.sqlite"));
        notes = new NoteStore(Path.Combine(Preferences.DirectoryPath, "notes.sqlite"));
        NotesView.Initialize(notes, this);
        NotesView.RecordingChanged += (_, _) => DispatcherQueue.TryEnqueue(UpdateGlobalRecording);
        NotesView.Changed += (_, _) => { _ = Guard(ReloadAsync); _ = Guard(SynchronizeAsync); };
        NotesView.TasksRequested += (_, _) => { _ = Guard(() => ChangeSectionAsync(section, false)); };
        calendar = new LocalCalendarProvider(Path.Combine(Preferences.DirectoryPath, "calendar.sqlite"));
        CalendarView.Initialize(calendar, this);
        ChatView.Initialize(Preferences.DirectoryPath, this, CaptureChatContextAsync, ApplyChatProposalAsync);
        ChatView.Changed += (_, _) => { if (!closing) { _ = Guard(ReloadAsync); _ = Guard(SynchronizeAsync); } };
        CalendarView.Changed += (_, _) => { calendarLinkSnapshot = null; _ = Guard(ReloadAsync); };
        CalendarView.TaskRequested += (_, args) => { _ = Guard(() => OpenCalendarTaskAsync(args.Workspace, args.TaskId)); };
        sync = new CloudSync(store, new ApiClient(http), new WindowsVault(), notes);
        ToastNotificationManagerCompat.OnActivated += args =>
        {
            var values = ToastArguments.Parse(args.Argument);
            if (values.TryGetValue("taskId", out var id) && values.TryGetValue("scope", out var scope))
                DispatcherQueue.TryEnqueue(() => { notification = (id, scope); _ = Guard(OpenNotificationAsync); });
            else if (values.TryGetValue("calendarEventId", out var eventId) && values.TryGetValue("calendarScope", out var eventScope))
                DispatcherQueue.TryEnqueue(() => QueueCalendarNotification(eventId, eventScope));
            else if (values.TryGetValue("notificationTest", out var test) && test == "1")
                DispatcherQueue.TryEnqueue(() => Activate());
        };
        Activated += async (_, args) => { if (ready && args.WindowActivationState != WindowActivationState.Deactivated) await Guard(SynchronizeAsync); };
        AppWindow.Closing += async (_, args) =>
        {
            try { NotesView.EnsureCanLeave(); }
            catch (InvalidOperationException error) { args.Cancel = true; ErrorBar.Title = "Note operation in progress"; ErrorBar.Message = error.Message; ErrorBar.IsOpen = true; return; }
            if (closing || !ready) return;
            if (ChatView.IsBusy)
            {
                args.Cancel = true;
                await Guard(async () => { await ChatView.StopAsync(); await SaveEditorAsync(); if (!Dirty()) { closing = true; Close(); } });
                return;
            }
            if (!Dirty()) return;
            args.Cancel = true;
            await Guard(async () => { await SaveEditorAsync(); if (!Dirty()) { closing = true; Close(); } });
        };
        Closed += async (_, _) =>
        {
            closing = true; lifetime.Cancel(); timer.Stop(); taskAutosave.Stop(); StopChangeFeed();
            CalendarView.ResetSubscriptionScope();
            try { await ChatView.StopAsync(); }
            catch (Exception) { System.Diagnostics.Debug.WriteLine("Takt: chat shutdown cleanup could not complete."); }
            finally
            {
                try { await calendar.DisposeAsync(); }
                catch (Exception) { System.Diagnostics.Debug.WriteLine("Takt: calendar shutdown cleanup could not complete."); }
            }
        };
        timer.Tick += async (_, _) => await Guard(async () => { await RolloverAsync(); await SynchronizeAsync(); });
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control, async () => await CreateTaskAsync()));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => { if (showingNotes) NotesView.FocusSearch(); else Search.Focus(FocusState.Programmatic); return Task.CompletedTask; }));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.S, VirtualKeyModifiers.Control, SaveEditorAsync));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Enter, VirtualKeyModifiers.Control, async () =>
        { if (draft is { } task && library.Tasks.FirstOrDefault(t => t.Id == task.Id) is { } current) await ChangeCompletion(task.Id, !current.Completed); }, () => !showingNotes && FocusWithin(WorkspaceGrid)));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, NewFolderAsync));
    }
    private KeyboardAccelerator Accelerator(VirtualKey key, VirtualKeyModifiers modifiers, Func<Task> action, Func<bool>? when = null)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += async (_, e) =>
        {
            if (!ready || FocusInDialog() || when is not null && !when()) return;
            e.Handled = true; await Guard(action);
        };
        return accelerator;
    }
    private async void Root_Loaded(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        try { preferences = Preferences.Read(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            preferences = new();
            ErrorBar.Title = "Settings unavailable";
            ErrorBar.Message = "Default settings are in use. Your task and note libraries are stored separately and have been kept.";
            ErrorBar.IsOpen = true;
        }
        ApplyTheme();
        await store.InitializeAsync();
        try { await notes.InitializeAsync(); notesReady = true; }
        catch (Exception) { sync.NotesEnabled = false; ErrorBar.Title = "Notes unavailable"; ErrorBar.Message = "The notes cache could not be opened. Task storage is separate and remains available."; ErrorBar.IsOpen = true; }
        foreach (var item in Navigation.MenuItems.OfType<NavigationViewItem>().Where(i => (i.Tag as string)?.StartsWith("notes:") == true)) item.IsEnabled = notesReady;
        ready = true;
        Navigation.SelectedItem = Navigation.MenuItems[0];
        await ReloadAsync(); timer.Start(); await OpenNotificationAsync(); await OpenCalendarNotificationAsync();
        if (!preferences.WelcomeSeen) await ShowWelcomeAsync();
        await SynchronizeAsync();
    });
    private void ApplyTheme() => Root.RequestedTheme = Enum.TryParse<ElementTheme>(preferences.Theme, out var theme) ? theme : ElementTheme.Default;
    private async Task Guard(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (closing) return;
            ErrorBar.Title = "Could not finish the action"; ErrorBar.Message = Message(error); ErrorBar.IsOpen = true;
        }
    }
    private static string Message(Exception error) => error switch
    {
        ApiException { Code: "library_not_initialized" } => "This account has no cloud library yet. In Sign in, explicitly choose to create an empty library, or initialize it on another device.",
        ApiException { Code: "support_unavailable" } => "Takt support is currently unavailable on this server. Your request is saved for retry.",
        ApiException { Code: "submission_reused" } => "This request code is already associated with other content. Change the draft before sending a new request.",
        ApiException { Code: "invalid_credentials", RetryAfter: > 0 } login => $"Check the email and password. Try signing in again in {login.RetryAfter} seconds.",
        ApiException { Code: "invalid_credentials" } => "Check the email and password and try again.",
        ApiException { Code: "email_not_verified" } => "Use Verify email to request a code and confirm your address.",
        ApiException { Code: "invalid_code" } => "The code is incorrect, expired, or already used. Check the code or request another one.",
        ApiException { Code: "registration_closed" } => "This server is not accepting registration for this address.",
        ApiException { Code: "invalid_password" } => "Use a password of 12 to 128 characters.",
        ApiException { Status: 401 } => "Sign in again to continue syncing. Your saved tasks and queued changes are kept on this device.",
        ApiException { Code: "library_exists" } => "This account already has a cloud library. Sign in using the existing library; local tasks have been kept separately.",
        ApiException { Code: "clock_skew" } => "Check the computer clock. The rejected change is kept for review.",
        ApiException { RetryAfter: > 0 } e => $"The server asked us to wait {e.RetryAfter} seconds before trying again.",
        ApiException e => "The server could not complete the request (" + e.Code + ").",
        HttpRequestException or TaskCanceledException => "The server is unavailable. Saved tasks and pending changes remain on this device.",
        ArgumentException or InvalidOperationException or InvalidDataException => error.Message,
        _ => "The action failed. Your existing library has been kept. Check disk space and permissions, then try again."
    };
    private async Task ReloadAsync()
    {
        await reloadGate.WaitAsync();
        try { await ReloadCoreAsync(); }
        finally { reloadGate.Release(); }
    }
    private async Task ReloadCoreAsync()
    {
        library = await store.ReadAsync();
        if (changeFeedProfile is not null && changeFeedProfile != library.Profile) StopChangeFeed();
        try { await ReconcileCalendarLinksAsync(); }
        catch (Exception) { if (calendarVisible) DisableCalendar(); }
        if (notesReady) noteState = await notes.ReadAsync(library.Workspace);
        if (draft is not null && !editing && !library.Tasks.Any(t => t.Id == draft.Id))
        {
            if (!Dirty()) draft = null;
            else { ErrorBar.Title = "Task deleted on another device"; ErrorBar.Message = "Your draft is still open. Save it to recover it as a new task."; ErrorBar.IsOpen = true; }
        }
        bool validSection = showingNotes ? section is "notes:all" or "notes:unfiled" or "notes:trash" : section is "inbox" or "today" or "week" or "month" or "all";
        bool sectionReset = !validSection && !library.Folders.Any(f => f.Id == section);
        if (sectionReset) section = showingNotes ? "notes:all" : "inbox";
        rendering = true;
        try
        {
            RefreshFolders();
            foreach (var item in Navigation.MenuItems.OfType<NavigationViewItem>())
                if (item.Tag is string key)
                {
                    int count = key.StartsWith("notes:", StringComparison.Ordinal)
                        ? noteState.InSection(key == "notes:unfiled" ? "inbox" : key, "", NoteDocument.Now).Count()
                        : showingNotes && Guid.TryParseExact(key, "D", out _) ? noteState.InSection(NoteDocument.FolderKey(key), "", NoteDocument.Now).Count()
                        : library.InSection(key, "", currentDay).Count(t => !t.Completed);
                    item.InfoBadge = new InfoBadge { Value = count, Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed };
                }
            var filtered = library.InSection(section, Search.Text.Trim(), currentDay).ToList();
            Reconcile(ActiveTasks, filtered.Where(t => !t.Completed).Select(t => new TaskRow(t, library)).ToList(), r => r.Id,
                (a, b) => a.Title == b.Title && a.Subtitle == b.Subtitle && a.DeadlineLabel == b.DeadlineLabel && a.Focused == b.Focused && a.Completed == b.Completed);
            Reconcile(CompletedTasks, filtered.Where(t => t.Completed).Select(t => new TaskRow(t, library)).ToList(), r => r.Id,
                (a, b) => a.Title == b.Title && a.Completed == b.Completed);
            SectionTitle.Text = SectionName(section); TaskCount.Text = $"Tasks: {filtered.Count}";
            EmptyList.Visibility = filtered.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            CompletedExpander.Header = $"Completed · {CompletedTasks.Count}";
            CompletedExpander.Visibility = CompletedTasks.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            TasksList.SelectedItem = ActiveTasks.FirstOrDefault(t => t.Id == draft?.Id);
            CompletedList.SelectedItem = CompletedTasks.FirstOrDefault(t => t.Id == draft?.Id);
            if (draft is not null && !editing && !Dirty()) FillEditor(library.Tasks.Single(t => t.Id == draft.Id));
            else if (draft is null) FillEditor(null);
            if (draft is not null && library.Tasks.FirstOrDefault(t => t.Id == draft.Id) is { } current)
            {
                EditorFocus.IsChecked = current.Focused(currentDay); EditorComplete.IsChecked = current.Completed;
                DeadlineSummary.Text = current.Deadline is { } deadline ? "Deadline · " + TaskRow.FormatDeadline(deadline) : "No deadline";
                Reconcile(ChecklistItems, library.Items(current.Id).Select(i => new ChecklistRow(i.Id, i.Text("title") ?? "", i.Flag("isCompleted"))).ToList(), i => i.Id, (a, b) => a == b);
            }
            FolderNotesSwitch.Visibility = notesReady && Guid.TryParseExact(section, "D", out _) ? Visibility.Visible : Visibility.Collapsed;
            FolderNotesSwitch.IsOn = showingNotes;
            AccountItem.Content = library.Profile?.Email ?? "Local library";
            int rejected = library.Queue.Count(q => q.Error is not null);
            QueueButton.Visibility = rejected > 0 ? Visibility.Visible : Visibility.Collapsed;
            SyncButton.IsEnabled = library.Profile is not null && !syncing;
            SyncStatus.Text = library.Profile is null ? "Saved on this device" : rejected > 0 ? $"{rejected} changes need attention" :
                library.Queue.Count > 0 ? $"Saved on this device · {library.Queue.Count} changes waiting to sync" : "Up to date";
        }
        finally { rendering = false; }
        if (showingNotes && notesReady)
        {
            if (sectionReset) await NotesView.OpenSectionAsync("notes:all", library);
            else await NotesView.RefreshAsync(library);
        }
        PlanTimeButton.IsEnabled = draft is not null && !showingNotes;
        ChecklistHeading.Text = draft is null ? "Subtasks" : $"Subtasks · {library.Items(draft.Id).Count(i => i.Flag("isCompleted"))}/{library.Items(draft.Id).Count()}";
        if (calendarVisible)
        {
            try { await RefreshCalendarContextAsync(); }
            catch (Exception) { DisableCalendar(); }
        }
        try { await RefreshChatWorkspaceAsync(); }
        catch (Exception) { ErrorBar.Title = "Chat history unavailable"; ErrorBar.Message = "Tasks and notes remain available. The local chat history could not be opened."; ErrorBar.IsOpen = true; }
        if (noteState.Error is not null) SyncStatus.Text += " · Notes need attention";
        else if (noteState.Pending > 0) SyncStatus.Text += $" · Notes: {noteState.Pending} pending";
        AdjustLayout();
        try { reminders.Update(library, preferences); }
        catch (Exception) { ErrorBar.Title = "Reminders unavailable"; ErrorBar.Message = "Tasks are saved. Windows could not update reminders; review notification settings."; ErrorBar.IsOpen = true; }
        await RefreshCalendarRemindersAsync();
        await RefreshScheduledBlocksAsync();
    }
    private void DisableCalendar()
    {
        calendarVisible = false; calendarContext = null; CalendarToggle.IsChecked = false;
        UpdateSidePanelVisibility();
        ErrorBar.Title = "Calendar unavailable";
        ErrorBar.Message = "The local calendar could not be opened. Tasks and notes remain available; calendar events have been kept.";
        ErrorBar.IsOpen = true;
    }
    private static void Reconcile<T>(ObservableCollection<T> target, IReadOnlyList<T> source, Func<T, string> key, Func<T, T, bool> equal)
    {
        var ids = source.Select(key).ToHashSet(StringComparer.Ordinal);
        for (int i = target.Count - 1; i >= 0; --i) if (!ids.Contains(key(target[i]))) target.RemoveAt(i);
        for (int i = 0; i < source.Count; ++i)
        {
            int old = -1;
            for (int j = i; j < target.Count; ++j) if (key(target[j]) == key(source[i])) { old = j; break; }
            if (old < 0) target.Insert(i, source[i]);
            else { if (old != i) target.Move(old, i); if (!equal(target[i], source[i])) target[i] = source[i]; }
        }
    }
    private string SectionName(string key) => key switch
    { "inbox" => "Inbox", "today" => "Today", "week" => "This Week", "month" => "Month", "all" => "All Tasks", _ => library.Folders.FirstOrDefault(f => f.Id == key)?.Text("name") ?? "Inbox" };
    private List<FolderChoice> Locations() => new[] { "inbox", "week", "month" }.Select(k => new FolderChoice(k, SectionName(k)))
        .Concat(library.Folders.Select(f => new FolderChoice(f.Id, f.Text("name") ?? "Folder"))).ToList();
    private void RefreshFolders()
    {
        string signature = string.Join("|", library.Folders.Select(f => f.Id + ":" + f.Text("name")));
        if (signature == folderSignature) return;
        folderSignature = signature;
        while (Navigation.MenuItems.Count > 9) Navigation.MenuItems.RemoveAt(9);
        foreach (var folder in library.Folders)
        {
            var item = new NavigationViewItem { Content = folder.Text("name"), Tag = folder.Id, Icon = new SymbolIcon(Symbol.Folder), AllowDrop = true };
            item.DragOver += Folder_DragOver; item.Drop += Folder_Drop;
            var menu = new MenuFlyout();
            void Command(string title, Func<Task> action)
            { var command = new MenuFlyoutItem { Text = title }; command.Click += async (_, _) => await Guard(action); menu.Items.Add(command); }
            Command("Open notes", () => ChangeSectionAsync(folder.Id, true));
            Command("Open tasks", () => ChangeSectionAsync(folder.Id, false));
            Command("Rename", () => RenameFolderAsync(folder));
            Command("Move up", () => ReorderFolderAsync(folder.Id, -1));
            Command("Move down", () => ReorderFolderAsync(folder.Id, 1));
            Command("Delete folder", () => DeleteFolderAsync(folder));
            item.ContextFlyout = menu; Navigation.MenuItems.Add(item);
        }
    }
    private bool Dirty() => showingNotes ? NotesView.IsDirty : draft is not null && (draftNeedsRecovery || TaskTitle.Text.Trim() != (draft.Text("title") ?? "") ||
        Description.Text != (draft.Text("description") ?? "") || Location.SelectedValue as string != draftLocation);
    private void FillEditor(Entity? task)
    {
        draft = task; draftNeedsRecovery = false; draftWorkspace = task is null ? null : library.Workspace; draftLocation = task is null ? null : library.Location(task);
        EditorScroll.Visibility = task is null ? Visibility.Collapsed : Visibility.Visible;
        EmptyEditor.Visibility = task is null ? Visibility.Visible : Visibility.Collapsed;
        AddItemButton.IsEnabled = DeadlineButton.IsEnabled = DeleteButton.IsEnabled = PlanTimeButton.IsEnabled = CopyTaskButton.IsEnabled = task is not null;
        if (task is null) { ChecklistItems.Clear(); return; }
        TaskTitle.Text = task.Text("title") ?? ""; Description.Text = task.Text("description") ?? "";
        Location.ItemsSource = Locations(); Location.SelectedValue = draftLocation;
        EditorFocus.IsChecked = task.Focused(currentDay); EditorComplete.IsChecked = task.Completed;
        CreatedAt.Text = DateTimeOffset.TryParse(task.Text("createdAt"), out var created) ? "Created " + created.ToLocalTime().ToString("g") : "";
        DeadlineSummary.Text = task.Deadline is { } d ? "Deadline · " + TaskRow.FormatDeadline(d) : "No deadline";
        Reconcile(ChecklistItems, library.Items(task.Id).Select(i => new ChecklistRow(i.Id, i.Text("title") ?? "", i.Flag("isCompleted"))).ToList(), i => i.Id, (a, b) => a == b);
    }
    private async Task ApplyAsync(IEnumerable<Edit> edits)
    {
        await store.EditAsync(library.Workspace, edits.ToList(), library.Profile is null ? 0 : sync.ClockOffset);
        await ReloadAsync(); _ = Guard(SynchronizeAsync);
    }
    private async Task SaveEditorAsync()
    {
        await taskSaveGate.WaitAsync();
        try { await SaveEditorCoreAsync(); }
        finally { taskSaveGate.Release(); }
    }
    private async Task SaveEditorCoreAsync()
    {
        if (showingNotes) { await NotesView.SaveAsync(); return; }
        if (draft is null || !Dirty()) return;
        if (editing) throw new InvalidOperationException("The task is being saved. Try again in a moment.");
        editing = true;
        try
        {
            // Drain input made while SQLite was committing before navigation can discard the editor.
            while (draft is { } original && Dirty())
            {
                string workspace = draftWorkspace ?? library.Workspace;
                if (workspace != library.Workspace) throw new InvalidOperationException("The active account changed. Reopen the task before saving.");
                string title = TaskTitle.Text.Trim(), description = Description.Text;
                string location = Location.SelectedValue as string ?? draftLocation ?? "inbox";
                string selectedLocation = location;
                TaskRules.Text(title, 16384, true); TaskRules.Text(description, 1048576);
                Entity baseline;
                if (!library.Tasks.Any(t => t.Id == original.Id))
                {
                    if (!await ConfirmAsync("Recover deleted task?", "The original was deleted on another device. Save this draft as a new task?", "Save as new task"))
                        throw new InvalidOperationException("The draft is still open. Copy it or save it as a new task before leaving.");
                    var recovered = TaskRules.CreateTask(title, library.Folders.Any(f => f.Id == location) || location is "inbox" or "week" or "month" ? location : "inbox");
                    recovered.Fields!["description"] = Wire.Value(description);
                    if (original.Deadline is { } deadline) recovered.Fields["deadline"] = Wire.Value(deadline);
                    recovered.Fields["focusDay"] = original.Focused(currentDay) ? Wire.Value("9999-12-31") : Wire.Null;
                    var recovery = new List<Edit> { recovered };
                    recovery.AddRange(ChecklistItems.Select((item, n) =>
                    {
                        var edit = TaskRules.CreateItem(recovered.Id, item.Title, n);
                        edit.Fields!["isCompleted"] = Wire.Value(item.Completed); return edit;
                    }));
                    await store.EditAsync(workspace, recovery, library.Profile is null ? 0 : sync.ClockOffset);
                    baseline = new(recovered.Id, "task", recovered.Fields, []);
                    location = baseline.Placement;
                }
                else
                {
                    Dictionary<string, JsonElement> fields = [];
                    if (title != original.Text("title")) fields["title"] = Wire.Value(title);
                    if (description != original.Text("description")) fields["description"] = Wire.Value(description);
                    if (location != draftLocation) fields["placement"] = TaskRules.Placement(location);
                    if (fields.Count == 0) return;
                    await store.EditAsync(workspace, [new(original.Id, "task", "update", fields)], library.Profile is null ? 0 : sync.ClockOffset);
                    var merged = new Dictionary<string, JsonElement>(original.Fields);
                    foreach (var (key, value) in fields) merged[key] = value;
                    baseline = original with { Fields = merged };
                }
                var committed = await store.ReadAsync();
                if (committed.Workspace != workspace) throw new InvalidOperationException("The active account changed. Your draft is still open.");
                library = committed;
                if (!committed.Tasks.Any(t => t.Id == baseline.Id))
                {
                    await ReloadAsync();
                    throw new InvalidOperationException("The task was deleted while saving. Your draft is still open; save again to recover it as a new task.");
                }
                if (location != selectedLocation && (Location.SelectedValue as string ?? draftLocation ?? "inbox") == selectedLocation)
                {
                    Location.ItemsSource = Locations(); Location.SelectedValue = location;
                }
                // Advance only the submitted field baseline. A concurrent remote update is not user input.
                draft = baseline; draftNeedsRecovery = false; draftLocation = location; draftWorkspace = workspace;
                await ReloadAsync();
                if (!library.Tasks.Any(t => t.Id == baseline.Id)) draftNeedsRecovery = true;
            }
        }
        finally { editing = false; }
        if (draft is { } saved && !Dirty() && library.Tasks.FirstOrDefault(t => t.Id == saved.Id) is { } current) FillEditor(current);
        _ = Guard(SynchronizeAsync);
    }
    private async Task SelectTaskAsync(string id)
    {
        await SaveEditorAsync();
        FillEditor(library.Tasks.FirstOrDefault(t => t.Id == id));
        AdjustLayout();
        await RefreshScheduledBlocksAsync();
        if (calendarVisible) await RefreshCalendarContextAsync();
    }
    private async Task SynchronizeAsync()
    {
        if (!ready || syncing || backupBusy || library.Profile is not { } profile || lifetime.IsCancellationRequested) return;
        syncing = true; SyncButton.IsEnabled = false; SyncStatus.Text = "Syncing…";
        try
        {
            await sync.SynchronizeAsync(lifetime.Token);
            await ReloadAsync();
            if (profile == library.Profile) StartChangeFeed(profile);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or ApiException)
        {
            await ReloadAsync(); SyncStatus.Text = e is ApiException { Status: 401 } ? "Sign in to resume syncing" :
                e is ApiException { RetryAfter: > 0 } a ? $"Sync paused · retry in {a.RetryAfter}s" : "Saved on this device · sync unavailable";
            if (e is ApiException { Status: 401 } && profile == library.Profile) { StopChangeFeed(); ErrorBar.Title = "Sign in required"; ErrorBar.Message = Message(e); ErrorBar.IsOpen = true; }
        }
        catch (Exception)
        {
            SyncStatus.Text = "Sync needs attention · local edits have been kept";
            throw;
        }
        finally { syncing = false; SyncButton.IsEnabled = library.Profile is not null; }
    }
    private async Task RolloverAsync()
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        if (currentDay != today) { currentDay = today; await ReloadAsync(); }
        else { reminders.Update(library, preferences); await RefreshCalendarRemindersAsync(); }
    }
    private async Task ChangeSectionAsync(string next, bool? noteMode = null)
    {
        await navigationGate.WaitAsync();
        try { await ChangeSectionCoreAsync(next, noteMode); }
        finally { navigationGate.Release(); }
    }
    private async Task ChangeSectionCoreAsync(string next, bool? noteMode)
    {
        await SaveEditorAsync();
        bool mode = noteMode ?? (next.StartsWith("notes:", StringComparison.Ordinal) || Guid.TryParseExact(next, "D", out _) && showingNotes);
        if (mode && !notesReady) throw new InvalidOperationException("The notes cache is unavailable.");
        showingNotes = mode; section = next; draft = null;
        rendering = true; Search.Text = ""; CompletedExpander.IsExpanded = false; rendering = false;
        WorkspaceGrid.Visibility = mode ? Visibility.Collapsed : Visibility.Visible; NotesView.Visibility = mode ? Visibility.Visible : Visibility.Collapsed;
        if (mode) await NotesView.OpenSectionAsync(next == "notes:unfiled" ? "inbox" : Guid.TryParseExact(next, "D", out _) ? NoteDocument.FolderKey(next) : next, library);
        await ReloadAsync();
    }
    private async void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!ready || rendering || navigating || args.SelectedItem is not NavigationViewItem { Tag: string next } || next == "account") return;
        navigating = true; await Guard(() => ChangeSectionAsync(next));
        rendering = true; Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => i.Tag as string == section); rendering = false;
        navigating = false;
    }
    private async void FolderNotes_Toggled(object sender, RoutedEventArgs e)
    { if (ready && !rendering && Guid.TryParseExact(section, "D", out _)) await Guard(() => ChangeSectionAsync(section, FolderNotesSwitch.IsOn)); }
    private async void Task_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (rendering || navigating || e.AddedItems.FirstOrDefault() is not TaskRow row) return;
        navigating = true; await Guard(() => SelectTaskAsync(row.Id)); navigating = false;
    }
    private async void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    { if (ready && !rendering) await Guard(ReloadAsync); }
    private async Task CreateTaskAsync()
    {
        if (showingNotes) { if (section == "notes:trash") await ChangeSectionAsync("notes:all", true); await NotesView.CreateNoteAsync(); return; }
        await SaveEditorAsync();
        var edit = TaskRules.CreateTask("New task", section);
        rendering = true; Search.Text = ""; rendering = false;
        await ApplyAsync([edit]); await SelectTaskAsync(edit.Id); TaskTitle.Focus(FocusState.Programmatic); TaskTitle.SelectAll();
    }
    private async void NewTask_Click(object sender, RoutedEventArgs e) { if (ready) await Guard(CreateTaskAsync); }
    private async void SaveTask_Click(object sender, RoutedEventArgs e) => await Guard(SaveEditorAsync);
    private async Task ChangeCompletion(string id, bool completed)
    {
        await SaveEditorAsync(); var task = library.Tasks.Single(t => t.Id == id);
        await ApplyAsync([TaskRules.Update(task, "completedAt", completed ? Wire.Value(Wire.Time()) : Wire.Null)]);
    }
    private async void Complete_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    { var button = (ToggleButton)sender; await ChangeCompletion((string)button.Tag, button.IsChecked == true); });
    private async void EditorComplete_Click(object sender, RoutedEventArgs e)
    { if (draft is { } task) await Guard(() => ChangeCompletion(task.Id, EditorComplete.IsChecked == true)); }
    private async Task ChangeFocus(string id, bool focused)
    {
        await SaveEditorAsync(); var task = library.Tasks.Single(t => t.Id == id);
        await ApplyAsync([TaskRules.Update(task, "focusDay", focused ? Wire.Value("9999-12-31") : Wire.Null)]);
    }
    private async void Focus_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    { var button = (ToggleButton)sender; await ChangeFocus((string)button.Tag, button.IsChecked == true); });
    private async void EditorFocus_Click(object sender, RoutedEventArgs e)
    { if (draft is { } task) await Guard(() => ChangeFocus(task.Id, EditorFocus.IsChecked == true)); }
    private async void DeleteTask_Click(object sender, RoutedEventArgs e) => await Guard(DeleteTaskAsync);
    private Task DeleteTaskAsync() => DeleteTaskCoreAsync(true);
    private async Task DeleteTaskCoreAsync(bool confirm)
    {
        await taskSaveGate.WaitAsync();
        try { await DeleteTaskUnlockedAsync(confirm); }
        finally { taskSaveGate.Release(); QueueTaskAutosave(); }
    }
    private async Task DeleteTaskUnlockedAsync(bool confirm)
    {
        taskAutosave.Stop();
        if (draft is not { } task) return;
        if (confirm && !await ConfirmAsync("Delete task?", "The task and its subtasks will be deleted on all synced devices.", "Delete")) return;
        await store.EditAsync(library.Workspace, TaskRules.DeleteTask(library, task), sync.ClockOffset);
        draft = null; await ReloadAsync(); _ = Guard(SynchronizeAsync);
    }
    private async Task<string?> PromptAsync(string title, string value, bool multiline = false)
    {
        var input = new TextBox { Text = value, PlaceholderText = title, TextWrapping = TextWrapping.Wrap, AcceptsReturn = multiline, MinHeight = multiline ? 96 : 0 };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = input, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text : null;
    }
    private async Task<bool> ConfirmAsync(string title, string message, string button) => await new ContentDialog
    { XamlRoot = Root.XamlRoot, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = button, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
    private async Task NewFolderAsync()
    {
        var name = await PromptAsync("New folder", ""); if (name is null) return;
        int order = checked(library.Folders.Select(f => f.Number("sortOrder")).DefaultIfEmpty(-1).Max() + 1);
        await ApplyAsync([TaskRules.CreateFolder(name, order)]);
    }
    private async void NewFolder_Click(object sender, RoutedEventArgs e) { if (ready) await Guard(NewFolderAsync); }
    private async Task RenameFolderAsync(Entity folder)
    {
        var name = await PromptAsync("Rename folder", folder.Text("name") ?? ""); if (name is null) return;
        var valid = TaskRules.CreateFolder(name, folder.Number("sortOrder")); await ApplyAsync([TaskRules.Update(folder, "name", valid.Fields!["name"])]);
    }
    private async Task ReorderFolderAsync(string id, int delta)
    {
        var folders = library.Folders.ToList(); int old = folders.FindIndex(f => f.Id == id), index = old + delta;
        if (old < 0 || index < 0 || index >= folders.Count) return;
        var folder = folders[old]; folders.RemoveAt(old); folders.Insert(index, folder);
        await ApplyAsync(folders.Select((f, n) => TaskRules.Update(f, "sortOrder", Wire.Value(n))));
    }
    private async Task DeleteFolderAsync(Entity folder)
    {
        await SaveEditorAsync();
        if (!await ConfirmAsync("Delete folder?", "Its tasks will move to Inbox. Task contents and deadlines will be kept.", "Delete folder")) return;
        if (notesReady) await notes.RehomeFolderAsync(library.Workspace, NoteDocument.FolderKey(folder.Id));
        if (section == folder.Id) { if (showingNotes) await ChangeSectionAsync("notes:all", true); else section = "inbox"; }
        await ApplyAsync(TaskRules.DeleteFolder(library, folder));
    }
    private void AddItem_Click(object sender, RoutedEventArgs e) => NewItemTitle.Focus(FocusState.Programmatic);
    private async Task CreateItemAsync()
    {
        if (showingNotes || draft is not { } clickedTask || string.IsNullOrWhiteSpace(NewItemTitle.Text)) return;
        string scope = library.Workspace, taskId = clickedTask.Id, text = NewItemTitle.Text;
        if (!await itemCreationGate.WaitAsync(0)) return;
        CreateSubtaskButton.IsEnabled = false;
        try
        {
            await SaveEditorAsync();
            if (showingNotes || library.Workspace != scope || draft?.Id != taskId)
                throw new InvalidOperationException("The selected task changed. Review the subtask text before adding it.");
            var task = library.Tasks.FirstOrDefault(t => t.Id == taskId) ?? throw new InvalidOperationException("The task was deleted. The subtask text has been kept.");
            int order = checked(library.Items(taskId).Select(i => i.Number("sortOrder")).DefaultIfEmpty(-1).Max() + 1);
            await store.EditTaskIfUnchangedAsync(scope, taskId, PlannerStore.TaskFingerprint(task, library.Items(taskId)),
                [TaskRules.CreateItem(taskId, text, order)], library.Profile is null ? 0 : sync.ClockOffset);
            await ReloadAsync(); _ = Guard(SynchronizeAsync);
            if (scope == library.Workspace && draft?.Id == taskId && NewItemTitle.Text == text) NewItemTitle.Text = "";
        }
        finally { itemCreationGate.Release(); CreateSubtaskButton.IsEnabled = draft is not null; }
    }
    private async void CreateItem_Click(object sender, RoutedEventArgs e) => await Guard(CreateItemAsync);
    private async void NewItem_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || ShiftPressed() || AltPressed()) return;
        e.Handled = true;
        if (string.IsNullOrWhiteSpace(NewItemTitle.Text)) Description.Focus(FocusState.Programmatic);
        else await Guard(CreateItemAsync);
    }
    private async void ItemComplete_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        var button = (CheckBox)sender; var item = library.Live.Single(i => i.Id == (string)button.Tag);
        await ApplyAsync([TaskRules.Update(item, "isCompleted", Wire.Value(button.IsChecked == true))]);
    });
    private async void RenameItem_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        var item = library.Live.Single(i => i.Id == (string)((Button)sender).Tag);
        var title = await PromptAsync("Edit subtask", item.Text("title") ?? "", true); if (title is null) return;
        TaskRules.Text(title, 16384, true); await ApplyAsync([TaskRules.Update(item, "title", Wire.Value(title.Trim()))]);
    });
    private async void DeleteItem_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    { var id = (string)((Button)sender).Tag; await ApplyAsync([new Edit(id, "checklistItem", "delete")]); });
    private async void Checklist_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        if (rendering || args.DropResult != DataPackageOperation.Move) return;
        await Guard(async () => await ApplyAsync(ChecklistItems.Select((row, index) =>
            TaskRules.Update(library.Live.Single(i => i.Id == row.Id), "sortOrder", Wire.Value(index)))));
    }
    private void Deadline_Click(object sender, RoutedEventArgs e)
    {
        if (draft is null) return;
        var parts = draft.Deadline?.LocalParts();
        DeadlineDate.Date = parts is null ? null : new DateTimeOffset(parts.Value.Date.ToDateTime(TimeOnly.MinValue), TimeZoneInfo.Local.GetUtcOffset(parts.Value.Date.ToDateTime(TimeOnly.MinValue)));
        IncludeTime.IsOn = parts?.Time is not null; DeadlineTime.SelectedTime = parts?.Time?.ToTimeSpan();
    }
    private void IncludeTime_Toggled(object sender, RoutedEventArgs e)
    { if (DeadlineTime is not null) DeadlineTime.Visibility = IncludeTime.IsOn ? Visibility.Visible : Visibility.Collapsed; }
    private void DeadlineToday_Click(object sender, RoutedEventArgs e) => DeadlineDate.Date = DateTimeOffset.Now.Date;
    private void DeadlineTomorrow_Click(object sender, RoutedEventArgs e) => DeadlineDate.Date = DateTimeOffset.Now.Date.AddDays(1);
    private async void ClearDeadline_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    { await SaveEditorAsync(); if (draft is { } task) await ApplyAsync([TaskRules.Update(task, "deadline", Wire.Null)]); DeadlineButton.Flyout.Hide(); });
    private async void ApplyDeadline_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        await SaveEditorAsync(); if (draft is not { } task || DeadlineDate.Date is not { } date) throw new ArgumentException("Choose a date.");
        if (IncludeTime.IsOn && DeadlineTime.SelectedTime is null) throw new ArgumentException("Choose a time.");
        // Keep an unchanged synced deadline's original time zone and instant.
        var oldParts = task.Deadline?.LocalParts();
        DateOnly day = DateOnly.FromDateTime(date.DateTime); TimeOnly? time = IncludeTime.IsOn ? TimeOnly.FromTimeSpan(DeadlineTime.SelectedTime!.Value) : null;
        if (oldParts is null || oldParts.Value.Date != day || oldParts.Value.Time != time)
        {
            var zone = task.Deadline is { } existing ? TimeZoneInfo.FindSystemTimeZoneById(existing.TimeZoneId) : TimeZoneInfo.Local;
            await ApplyAsync([TaskRules.Update(task, "deadline", Wire.Value(Deadline.FromLocal(day, time, zone)))]);
        }
        DeadlineButton.Flyout.Hide();
    });
    private void Tasks_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        e.Data.SetData(DragFormat, JsonSerializer.Serialize(new { workspace = library.Workspace, ids = e.Items.Cast<TaskRow>().Select(t => t.Id).ToArray() }));
        e.Data.RequestedOperation = DataPackageOperation.Move;
    }
    private void Folder_DragOver(object sender, DragEventArgs e)
    { if (e.DataView.Contains(DragFormat) || e.DataView.Contains(NotesWorkspace.DragFormat) && Guid.TryParseExact(((NavigationViewItem)sender).Tag as string, "D", out _)) { e.AcceptedOperation = DataPackageOperation.Move; e.Handled = true; } }
    private async void Folder_Drop(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(NotesWorkspace.DragFormat))
        {
            var noteDeferral = e.GetDeferral();
            await Guard(async () =>
            {
                string target = (string)((NavigationViewItem)sender).Tag;
                if (!Guid.TryParseExact(target, "D", out _)) return;
                using var payload = JsonDocument.Parse((string)await e.DataView.GetDataAsync(NotesWorkspace.DragFormat));
                if (payload.RootElement.GetProperty("workspace").GetString() != library.Workspace) throw new InvalidOperationException("Move notes within the active library.");
                foreach (var id in payload.RootElement.GetProperty("ids").EnumerateArray()) await NotesView.MoveAsync(id.GetString()!, NoteDocument.FolderKey(target));
            });
            e.Handled = true; noteDeferral.Complete(); return;
        }
        if (!e.DataView.Contains(DragFormat)) return;
        var deferral = e.GetDeferral();
        await Guard(async () =>
        {
            await SaveEditorAsync(); using var data = JsonDocument.Parse((string)await e.DataView.GetDataAsync(DragFormat));
            if (data.RootElement.GetProperty("workspace").GetString() != library.Workspace) throw new InvalidOperationException("Move tasks within the active library.");
            string destination = (string)((NavigationViewItem)sender).Tag;
            var ids = data.RootElement.GetProperty("ids").EnumerateArray().Select(i => i.GetString()!).ToList();
            await ApplyAsync(TaskRules.Move(library, ids, destination));
        });
        e.Handled = true; deferral.Complete();
    }
    private async void TaskList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Delete && (sender as ListView)?.SelectedItem is TaskRow row && draft?.Id == row.Id)
        { e.Handled = true; await Guard(() => DeleteTaskCoreAsync(false)); }
    }
    private void Title_KeyDown(object sender, KeyRoutedEventArgs e)
    { if (e.Key == VirtualKey.Enter) { e.Handled = true; Description.Focus(FocusState.Programmatic); } }
    private void Description_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || ShiftPressed() || Description.SelectionLength != 0) return;
        int start = Description.SelectionStart; string before = Description.Text[..start];
        string line = before[(before.LastIndexOf('\n') + 1)..].TrimEnd('\r');
        var match = System.Text.RegularExpressions.Regex.Match(line, @"^(\s*)([-*•]|\d+[.)]) (.*)$");
        if (!match.Success) return;
        string marker = match.Groups[2].Value;
        if (int.TryParse(marker[..^1], out int number) && number < int.MaxValue) marker = (number + 1).ToString() + marker[^1];
        string insertion = "\r\n" + match.Groups[1].Value + marker + " ";
        if (match.Groups[3].Value.Length == 0) { Description.Text = Description.Text.Remove(start - line.Length, line.Length); Description.SelectionStart = start - line.Length; }
        else { Description.Text = Description.Text.Insert(start, insertion); Description.SelectionStart = start + insertion.Length; }
        e.Handled = true;
    }
    private async void Sync_Click(object sender, RoutedEventArgs e) => await Guard(SynchronizeAsync);
    private async void Account_Tapped(object sender, TappedRoutedEventArgs e) => await Guard(ShowAccountAsync);
    private async Task ShowAccountAsync()
    {
        if (!ready || accountDialogOpen) return;
        accountDialogOpen = true;
        try
        {
            NotesView.EnsureCanLeave();
            StopChangeFeed();
            CalendarView.ResetSubscriptionScope();
            await ChatView.StopAsync();
            await proposalGate.WaitAsync();
            try
            {
                var current = await store.ConnectionAsync();
                string origin = current?.Profile.Origin ?? CloudSync.DefaultOrigin;
                string email = current?.Profile.Email ?? "";
                while (!lifetime.IsCancellationRequested)
                {
                    var entry = await ShowAccountCoreAsync(origin, email);
                    if (entry.Action is not { } action) break;
                    (origin, email) = await ShowEmailAccountActionAsync(action, entry.Origin, entry.Email);
                }
                if (!closing) { await ReloadAsync(); await SynchronizeAsync(); }
            }
            finally { proposalGate.Release(); }
        }
        finally { accountDialogOpen = false; }
    }
    private async Task<(EmailAccountAction? Action, string Origin, string Email)> ShowAccountCoreAsync(string address, string emailAddress)
    {
        NotesView.EnsureCanLeave(); await SaveEditorAsync();
        var current = await store.ConnectionAsync();
        var origin = new TextBox { Header = "Server", Text = address, MaxLength = 2048 };
        var email = new TextBox { Header = "Email", Text = emailAddress, MaxLength = 254,
            InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.EmailSmtpAddress) } } };
        var password = new PasswordBox { Header = "Password" };
        var initialize = new CheckBox { Content = "Create a cloud library if this account has none" };
        var upload = new CheckBox { Content = "Include my local tasks in the new cloud library", IsEnabled = library.Profile is null && library.Tasks.Any() };
        var localTasks = library.Profile is null ? library.Live.Where(t => t.Type is "task" or "folder" or "checklistItem").ToList() : [];
        var detail = new TextBlock { Text = "Sign in with your Takt account. You can choose whether to copy your local tasks when creating a cloud library.", TextWrapping = TextWrapping.Wrap };
        if (accountNotice is { } notice) { detail.Text = notice; accountNotice = null; }
        var problem = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"] };
        var actions = new StackPanel { Spacing = 4 };
        var content = new StackPanel { Spacing = 12, Children = { detail, origin, email, password, initialize, upload, actions, problem } };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Takt account", Content = new ScrollViewer { Content = content, MaxHeight = 560 }, PrimaryButtonText = "Sign in", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            SecondaryButtonText = current is null ? "" : "Sign out" };
        EmailAccountAction? next = null;
        bool busy = false;
        void AddAction(string label, EmailAccountAction action)
        {
            var link = new HyperlinkButton { Content = label };
            link.Click += (_, _) =>
            {
                if (busy) return;
                next = action;
                dialog.Hide();
            };
            actions.Children.Add(link);
        }
        AddAction("Create account…", EmailAccountAction.Register);
        AddAction("Verify email…", EmailAccountAction.Verify);
        AddAction("Forgot password?", EmailAccountAction.ResetPassword);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral(); args.Cancel = true; busy = true; dialog.IsPrimaryButtonEnabled = false; dialog.IsSecondaryButtonEnabled = false;
            try
            {
                if (upload.IsChecked == true && initialize.IsChecked != true) throw new ArgumentException("Choose to create a cloud library before including local tasks.");
                await sync.LoginAsync(origin.Text, email.Text, password.Password, initialize.IsChecked == true,
                    upload.IsChecked == true ? localTasks : null, lifetime.Token);
                password.Password = ""; draft = null; args.Cancel = false;
            }
            catch (Exception error) { password.Password = ""; problem.Text = Message(error); }
            finally { busy = false; dialog.IsPrimaryButtonEnabled = true; dialog.IsSecondaryButtonEnabled = true; deferral.Complete(); }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral(); busy = true; dialog.IsPrimaryButtonEnabled = false;
            try { await sync.LogoutAsync(lifetime.Token); draft = null; }
            catch (Exception error) { problem.Text = Message(error); }
            finally
            {
                // Logout switches to the local library even when revoking the server session fails.
                try { if ((await store.ReadAsync()).Workspace != draftWorkspace) FillEditor(null); }
                finally { busy = false; dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
            }
        };
        try { await dialog.ShowAsync(); }
        finally { password.Password = ""; }
        return (next, origin.Text, email.Text.Trim());
    }
    private async void Queue_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        var rejected = library.Queue.Where(q => q.Error is not null).ToList();
        string text = string.Join("\n", rejected.Select(q => $"{q.Mutation.EntityType} · {q.Mutation.EntityId} · {q.Error}"));
        if (await ConfirmAsync("Changes that could not sync", text + "\n\nDiscard only these rejected edits? Confirmed server data and other pending edits will be kept.", "Discard rejected edits"))
        { await store.DiscardRejectedAsync(library.Workspace); await ReloadAsync(); }
    });
    private async void Settings_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        await SaveEditorAsync();
        var theme = new ComboBox { Header = "Appearance", ItemsSource = new[] { "Default", "Light", "Dark" }, SelectedItem = preferences.Theme };
        var deadlines = new ToggleSwitch { Header = "Deadline reminders", IsOn = preferences.DeadlineReminders };
        var hour = new NumberBox { Header = "Date-only deadline hour", Minimum = 0, Maximum = 23, SmallChange = 1, Value = preferences.DateOnlyHour };
        var review = new ToggleSwitch { Header = "Time to review your tasks", IsOn = preferences.ReviewReminder };
        var reviewTime = new TimePicker { Header = "Review reminder time", SelectedTime = new TimeSpan(preferences.ReviewHour, preferences.ReviewMinute, 0) };
        var weekdays = new CheckBox { Content = "Review on weekdays only", IsChecked = preferences.WeekdaysOnly };
        var testNotification = new Button { Content = "Test notification" };
        var notificationStatus = new InfoBar { IsClosable = true };
        testNotification.Click += (_, _) =>
        {
            try
            {
                reminders.ScheduleTest();
                notificationStatus.Severity = InfoBarSeverity.Informational;
                notificationStatus.Message = "Test scheduled for five seconds from now.";
            }
            catch (Exception error)
            {
                notificationStatus.Severity = InfoBarSeverity.Error;
                notificationStatus.Message = error is InvalidOperationException ? error.Message
                    : "Windows could not schedule the test notification. Check your notification settings.";
            }
            notificationStatus.IsOpen = true;
        };
        bool assistantRequested = false, supportRequested = false, calendarRequested = false, backupRequested = false;
        var libraryBackup = new Button { Content = "Library backup…" };
        var calendarSettings = new Button { Content = "Calendar settings…" };
        var support = new Button { Content = "Contact support…" };
        var assistant = new Button { Content = "AI connections and models…", IsEnabled = !ChatView.IsBusy };
        var export = new Button { Content = "Export task backup" }; var import = new Button { Content = "Import tasks into local library", IsEnabled = library.Profile is null };
        var stack = new StackPanel { Spacing = 12, Children = { theme, deadlines, hour, review, reviewTime, weekdays, testNotification, notificationStatus, calendarSettings, assistant, libraryBackup, export, import, support } };
        export.Click += async (_, _) => await Guard(ExportAsync); import.Click += async (_, _) => await Guard(ImportAsync);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Settings", Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        assistant.Click += (_, _) => { assistantRequested = true; dialog.Hide(); };
        support.Click += (_, _) => { supportRequested = true; dialog.Hide(); };
        calendarSettings.Click += (_, _) => { calendarRequested = true; dialog.Hide(); };
        libraryBackup.Click += (_, _) => { backupRequested = true; dialog.Hide(); };
        var result = await dialog.ShowAsync();
        if (supportRequested) { await ShowSupportAsync(); return; }
        if (backupRequested) { await ShowLibraryBackupAsync(); return; }
        if (calendarRequested)
        {
            calendarVisible = true;
            chatVisible = false;
            UpdateSidePanelVisibility();
            await RefreshCalendarContextAsync();
            await CalendarView.ShowSettingsAsync();
            return;
        }
        if (assistantRequested)
        {
            chatVisible = true; calendarVisible = false; UpdateSidePanelVisibility();
            try { await RefreshChatWorkspaceAsync(); }
            catch (Exception) { ErrorBar.Title = "Chat history unavailable"; ErrorBar.Message = "You can still manage AI connections. The local conversation history could not be opened."; ErrorBar.IsOpen = true; }
            await ChatView.ShowSettingsAsync(); return;
        }
        if (result == ContentDialogResult.Primary)
        {
            if (!double.IsFinite(hour.Value) || hour.Value < 0 || hour.Value > 23 || hour.Value % 1 != 0 || reviewTime.SelectedTime is null)
                throw new ArgumentException("Choose a date-only deadline hour and a review time.");
            var chosen = reviewTime.SelectedTime.Value;
            preferences = preferences with
            {
                Theme = (string)theme.SelectedItem, DeadlineReminders = deadlines.IsOn, DateOnlyHour = (int)hour.Value,
                ReviewReminder = review.IsOn, ReviewHour = chosen.Hours, WeekdaysOnly = weekdays.IsChecked == true, ReviewMinute = chosen.Minutes
            };
            preferences.Save(); ApplyTheme(); await ReloadAsync();
        }
    });
    private async Task ExportAsync()
    {
        var picker = new FileSavePicker { SuggestedFileName = "Takt-tasks-" + DateTime.Today.ToString("yyyy-MM-dd") };
        picker.FileTypeChoices.Add("Takt task backup", new List<string> { ".json" }); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is { } file) await FileIO.WriteTextAsync(file, TaskBackup.Export(library));
    }
    private async Task ImportAsync()
    {
        var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".json"); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        if ((await file.GetBasicPropertiesAsync()).Size > 32 * 1024 * 1024) throw new InvalidDataException("Backup is too large.");
        var edits = TaskBackup.Import(await FileIO.ReadTextAsync(file), library); await ApplyAsync(edits);
    }
    private async Task OpenNotificationAsync()
    {
        if (!ready || notification is not { } pending) return;
        notification = null;
        await ReloadAsync();
        if (pending.Scope != WindowsReminders.Scope(library.Workspace))
        { ErrorBar.Title = "Another library"; ErrorBar.Message = "Sign in to the library that owns this reminder."; ErrorBar.IsOpen = true; return; }
        if (pending.Task.StartsWith("review-", StringComparison.Ordinal)) await ChangeSectionAsync("today", false);
        else if (library.Tasks.Any(t => t.Id == pending.Task)) { await ChangeSectionAsync("all", false); await SelectTaskAsync(pending.Task); }
        Activate();
    }
    private void Root_SizeChanged(object sender, SizeChangedEventArgs e) => AdjustLayout();
    private void AdjustLayout()
    {
        if (WorkspaceGrid is null || DocumentViews is null || DocumentsAndPanel is null) return;
        bool panel = calendarVisible || chatVisible;
        bool panelOnly = panel && DocumentsAndPanel.ActualWidth < 700;
        Navigation.PaneDisplayMode = Root.ActualWidth < 900 ? NavigationViewPaneDisplayMode.LeftMinimal : NavigationViewPaneDisplayMode.Auto;
        DocumentViews.Visibility = panelOnly ? Visibility.Collapsed : Visibility.Visible;
        DocumentsColumn.Width = panelOnly ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        PanelResize.Visibility = panel && !panelOnly ? Visibility.Visible : Visibility.Collapsed;
        PanelSplitterColumn.Width = new GridLength(panel && !panelOnly ? 16 : 0);
        RightPanelColumn.Width = panelOnly ? new GridLength(1, GridUnitType.Star) : new GridLength(panel ? panelWidth : 0);
        bool narrow = Root.ActualWidth < 1000 || WorkspaceGrid.ActualWidth < 720;
        ListPane.Visibility = narrow && draft is not null ? Visibility.Collapsed : Visibility.Visible;
        DetailPane.Visibility = narrow && draft is null ? Visibility.Collapsed : Visibility.Visible;
        ResizeHandle.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        BackButton.Visibility = narrow && draft is not null ? Visibility.Visible : Visibility.Collapsed;
        ListColumn.MinWidth = narrow ? 0 : 260; EditorColumn.MinWidth = narrow ? 0 : 300;
        SplitterColumn.Width = new GridLength(narrow ? 0 : 16);
        if (narrow)
        {
            Grid.SetColumn(DetailPane, 0); Grid.SetColumnSpan(DetailPane, 3); Grid.SetColumnSpan(ListPane, 3);
            ListColumn.Width = new GridLength(1, GridUnitType.Star); EditorColumn.Width = new GridLength(0);
        }
        else
        {
            Grid.SetColumn(DetailPane, 2); Grid.SetColumnSpan(DetailPane, 1); Grid.SetColumnSpan(ListPane, 1);
            ListColumn.Width = new GridLength(resizeWidth > 0 ? resizeWidth : 350); EditorColumn.Width = new GridLength(1, GridUnitType.Star);
        }
    }
    private async void Back_Click(object sender, RoutedEventArgs e) => await Guard(async () => { await SaveEditorAsync(); draft = null; await ReloadAsync(); });
    private void Resize_DragStarted(object sender, DragStartedEventArgs e) => resizeWidth = ListColumn.ActualWidth;
    private void Resize_DragDelta(object sender, DragDeltaEventArgs e) => ResizeList(resizeWidth + e.HorizontalChange);
    private void Resize_DragCompleted(object sender, DragCompletedEventArgs e) => resizeWidth = ListColumn.ActualWidth;
    private void Resize_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (VirtualKey.Left or VirtualKey.Right or VirtualKey.Home)) return;
        ResizeList(e.Key == VirtualKey.Home ? 350 : ListColumn.ActualWidth + (e.Key == VirtualKey.Left ? -16 : 16));
        e.Handled = true;
    }
    private void ResizeList(double width)
    {
        resizeWidth = Math.Clamp(width, 260, Math.Max(260, WorkspaceGrid.ActualWidth - 340));
        ListColumn.Width = new GridLength(resizeWidth);
    }
}
