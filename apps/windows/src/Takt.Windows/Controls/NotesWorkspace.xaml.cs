using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using System.Collections.ObjectModel;
using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Notes;
using Takt.Windows.Services;
using Takt.Windows.ViewModels;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;
using global::Windows.System;
using WinRT.Interop;

namespace Takt.Windows.Controls;

public sealed partial class NotesWorkspace : UserControl
{
    public const string DragFormat = "application/x-takt-note";
    public ObservableCollection<NoteRow> Rows { get; } = [];
    private readonly SharedNoteEditor editor;
    private readonly DispatcherTimer autosave = new() { Interval = TimeSpan.FromMilliseconds(750) };
    private readonly SemaphoreSlim saving = new(1, 1);
    private readonly SemaphoreSlim operations = new(1, 1);
    private long editVersion;
    private NoteStore store = null!;
    private Window owner = null!;
    private Library library = Library.Empty;
    private NotesState state = NotesState.Empty;
    private StoredNote? draft;
    private string section = "notes:all";
    private bool loading, bodyDirty, titleDirty, folderDirty;
    private double listWidth = 350;
    private Task editingOperation = Task.CompletedTask;
    private Task presentation = Task.CompletedTask;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    public string? SelectedNoteId => draft?.Document.Id;
    public bool IsDirty => draft is not null && (bodyDirty || titleDirty || folderDirty);
    public bool IsRecording => recorder.IsRecording;
    public event EventHandler? Changed;
    public event EventHandler? TasksRequested;
    public NotesWorkspace()
    {
        InitializeComponent(); editor = new(NoteBody);
        autosave.Tick += async (_, _) => { autosave.Stop(); await Run(SaveCoreAsync); };
    }
    public void Initialize(NoteStore noteStore, Window window) { store = noteStore; owner = window; }
    // One UI transaction at a time. Core methods call each other without taking
    // this gate again; public entry points also cover shell/sync callbacks.
    private async Task SerializeAsync(Func<Task> action)
    {
        await operations.WaitAsync();
        try { await action(); }
        finally { operations.Release(); }
    }
    private async Task WithEditorLockedAsync(Func<Task> action)
    {
        bool enabled = NoteEditorScroll.IsEnabled; NoteEditorScroll.IsEnabled = false;
        try { await action(); }
        finally { NoteEditorScroll.IsEnabled = enabled; }
    }
    public Task OpenSectionAsync(string next, Library tasks) => SerializeAsync(() => OpenSectionCoreAsync(next, tasks));
    public Task RefreshAsync(Library tasks) => SerializeAsync(() => RefreshCoreAsync(tasks));
    public Task SaveAsync() => SerializeAsync(SaveCoreAsync);
    public Task CreateNoteAsync() => SerializeAsync(CreateNoteCoreAsync);
    public Task MoveAsync(string id, string folder) => SerializeAsync(() => MoveCoreAsync(id, folder));
    public Task TrashSelectedAsync() => SerializeAsync(TrashSelectedCoreAsync);
    public void FocusSearch() => NotesSearch.Focus(FocusState.Programmatic);
    private async Task OpenSectionCoreAsync(string next, Library tasks)
    {
        await SaveCoreAsync();
        if (library.Workspace != tasks.Workspace) EnsureNotRecording();
        await WithEditorLockedAsync(async () =>
        {
            library = tasks; section = next; draft = null; loading = true; NotesSearch.Text = ""; loading = false;
            await RefreshCoreAsync(tasks);
        });
    }
    private async Task RefreshCoreAsync(Library tasks)
    {
        await editingOperation; await presentation;
        await refreshGate.WaitAsync();
        try
        {
        if (library.Workspace != tasks.Workspace) { if (IsDirty) throw new InvalidOperationException("Save the note before switching libraries."); EnsureNotRecording(); draft = null; }
        library = tasks;
        var expired = await store.PurgeExpiredAsync(tasks.Workspace, NoteDocument.Now);
        state = await store.ReadAsync(tasks.Workspace);
        foreach (var removed in state.Notes.Where(n => n.Document.IsPurged))
        {
            if (recordingWorkspace == tasks.Workspace && recordingNoteId == removed.Document.Id && recorder.IsRecording) await StopRecordingAsync();
            if (transcriptionContext is { } context && context.Workspace == tasks.Workspace && context.NoteId == removed.Document.Id)
            {
                var finished = transcriptionFinished?.Task; transcribing?.Cancel();
                if (finished is not null) await finished;
            }
            audio.Purge(tasks.Workspace, removed.Document.Id);
        }
        loading = true;
        try
        {
            var visible = state.InSection(section, NotesSearch.Text.Trim(), NoteDocument.Now).Select(NoteRow.From).ToList();
            // Preserve row identity and native selection; never select a neighbor after trashing.
            for (int i = Rows.Count - 1; i >= 0; --i) if (!visible.Any(n => n.Id == Rows[i].Id)) Rows.RemoveAt(i);
            for (int i = 0; i < visible.Count; ++i)
            {
                int old = Rows.ToList().FindIndex(n => n.Id == visible[i].Id);
                if (old < 0) Rows.Insert(i, visible[i]); else { if (old != i) Rows.Move(old, i); if (Rows[i] != visible[i]) Rows[i] = visible[i]; }
            }
            NotesHeading.Text = section switch { "notes:all" => "All Notes", "notes:trash" => "Recently Deleted", "inbox" => "Unfiled Notes", _ => library.Folders.FirstOrDefault(f => NoteDocument.FolderKey(f.Id) == section)?.Text("name") ?? "Notes" };
            NotesCount.Text = $"Notes: {visible.Count}";
            EmptyNotes.Visibility = visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            TrashHint.Visibility = section == "notes:trash" ? Visibility.Visible : Visibility.Collapsed;
            CreateNoteButton.Visibility = section == "notes:trash" ? Visibility.Collapsed : Visibility.Visible;
            NewNoteToolbar.IsEnabled = section != "notes:trash";
            FolderTasksButton.Visibility = section.StartsWith("folder-", StringComparison.Ordinal) ? Visibility.Visible : Visibility.Collapsed;
            NotesList.SelectedItem = Rows.FirstOrDefault(n => n.Id == draft?.Document.Id);
            var current = state.Notes.FirstOrDefault(n => n.Document.Id == draft?.Document.Id);
            if (draft is not null && !IsDirty)
            {
                if (current is null || current.Document.IsPurged || current.Document.Expired(NoteDocument.Now)) await ShowAsync(null);
                else if (current.Digest != draft.Digest) await ShowAsync(current);
            }
            if (draft is null) await ShowAsync(null);
            if (state.Error is { } problem) ShowProblem("Notes sync", problem);
        }
        finally { loading = false; }
        UpdateLayout();
        }
        finally
        {
            refreshGate.Release();
        }
    }
    private async Task ShowAsync(StoredNote? note)
    {
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); presentation = completed.Task;
        bool previous = loading; loading = true;
        try
        {
            NoteTitle.IsReadOnly = true; NoteFolder.IsEnabled = false; NoteBody.IsReadOnly = true; FormatBar.IsEnabled = false;
            draft = note; bodyDirty = titleDirty = folderDirty = false;
            NoteEditorScroll.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
            NoNoteSelected.Visibility = note is null ? Visibility.Visible : Visibility.Collapsed;
            PinNoteButton.IsEnabled = TrashNoteButton.IsEnabled = note is not null && note.Document.DeletedAt is null;
            RestoreNoteButton.Visibility = note?.Document.DeletedAt is not null ? Visibility.Visible : Visibility.Collapsed;
            RecordNoteButton.IsEnabled = RecordCallButton.IsEnabled = !IsRecording && note is not null && note.Document.DeletedAt is null;
            if (note is null) { AudioClips.ItemsSource = null; return; }
            var document = note.Document; NoteTitle.Text = document.Title;
            NoteFolder.ItemsSource = new[] { new FolderChoice("inbox", "Unfiled") }.Concat(library.Folders.Select(f => new FolderChoice(NoteDocument.FolderKey(f.Id), f.Text("name") ?? "Folder"))).ToList();
            NoteFolder.SelectedValue = document.FolderId() is { } id && library.Folders.Any(f => f.Id == id) ? document.Folder : "inbox";
            PinNoteButton.IsChecked = document.Pinned;
            NoteUpdated.Text = "Updated " + NoteDocument.Date(document.UpdatedAt).ToLocalTime().ToString("f");
            NoteBody.IsReadOnly = true;
            await editor.LoadAsync(document);
            NoteTitle.IsReadOnly = document.DeletedAt is not null; NoteFolder.IsEnabled = document.DeletedAt is null;
            NoteBody.IsReadOnly = document.DeletedAt is not null;
            FormatBar.IsEnabled = !NoteBody.IsReadOnly;
            AudioClips.ItemsSource = audio.List(library.Workspace, document.Id);
        }
        finally { loading = previous; completed.TrySetResult(); presentation = Task.CompletedTask; }
    }
    private async Task SaveCoreAsync()
    {
        autosave.Stop(); await editingOperation; await presentation;
        await saving.WaitAsync();
        try
        {
            if (!IsDirty || draft is null || loading) return;
            while (IsDirty && draft is { } original && !loading)
            {
            long capturedVersion = editVersion;
            string workspace = library.Workspace;
            var note = original.Document;
            if (note.DeletedAt is not null) throw new InvalidOperationException("Restore the note before editing it.");
            if (bodyDirty)
            {
                var content = editor.Capture(); note = note with { Text = content.Text, Document = "", RichText = content.RichText };
            }
            if (titleDirty) note = note with { Title = NoteTitle.Text.Trim() };
            if (folderDirty && NoteFolder.SelectedValue is string folder) note = note with { Folder = folder };
            note = note with { UpdatedAt = NoteDocument.Now };
            var current = await store.FindAsync(workspace, note.Id);
            if (current?.Document.IsPurged == true || current?.Document.Expired(NoteDocument.Now) == true)
            {
                if (!await Confirm("Recover removed note?", "Save your open draft as a new note? The permanently removed original will remain removed.", "Save a copy")) throw new InvalidOperationException("Your draft is still open.");
                note = note.Copy() with { DeletedAt = null, Purged = null }; original = new(note, "", null);
            }
            var saved = await store.SaveAsync(workspace, current?.Document.IsPurged == true || current?.Document.Expired(NoteDocument.Now) == true ? null : original.Digest, note);
            string previousId = draft.Document.Id;
            draft = saved;
            if (editVersion == capturedVersion) bodyDirty = titleDirty = folderDirty = false;
            if (saved.Document.Id != previousId)
            {
                try { audio.Copy(library.Workspace, previousId, saved.Document.Id); }
                catch (IOException) { ShowProblem("Recording copy incomplete", "The note was saved. Its original recordings are still available with the original note."); }
                ShowProblem("Both versions kept", "The note changed elsewhere. Your edits were saved as a separate copy.");
            }
            // Do not reload the rich document on autosave: selection, undo history,
            // scroll position and typing attributes must remain intact.
            NoteUpdated.Text = "Updated " + NoteDocument.Date(saved.Document.UpdatedAt).ToLocalTime().ToString("f");
            }
            await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
        }
        finally { saving.Release(); }
    }
    private async Task CreateNoteCoreAsync()
    {
        await SaveCoreAsync();
        await WithEditorLockedAsync(async () =>
        {
        var note = NoteDocument.Create(section.StartsWith("folder-", StringComparison.Ordinal) ? section : "inbox");
        var saved = await store.SaveAsync(library.Workspace, null, note);
        if (section == "notes:trash") section = "notes:all";
        loading = true; NotesSearch.Text = ""; loading = false;
        await ShowAsync(saved); await RefreshCoreAsync(library); UpdateLayout(); NoteTitle.Focus(FocusState.Programmatic);
        Changed?.Invoke(this, EventArgs.Empty);
        });
    }
    private async Task MoveCoreAsync(string id, string folder)
    {
        await SaveCoreAsync();
        await WithEditorLockedAsync(async () =>
        {
        var note = await store.FindAsync(library.Workspace, id) ?? throw new InvalidOperationException("The note no longer exists.");
        if (note.Document.DeletedAt is not null) throw new InvalidOperationException("Restore the note before moving it.");
        await store.SaveAsync(library.Workspace, note.Digest, note.Document with { Folder = folder, UpdatedAt = NoteDocument.Now });
        await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
        });
    }
    private async Task MetadataAsync(Func<NoteDocument, NoteDocument> edit)
    {
        await SaveCoreAsync(); if (draft is not { } current) return;
        await WithEditorLockedAsync(async () =>
        {
        var saved = await store.SaveAsync(library.Workspace, current.Digest, edit(current.Document) with { UpdatedAt = NoteDocument.Now });
        await ShowAsync(saved); await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
        });
    }
    private void ScheduleSave() { if (loading || draft is null || NoteBody.IsReadOnly && NoteTitle.IsReadOnly) return; autosave.Stop(); autosave.Start(); }
    private async Task Run(Func<Task> action)
    {
        try { await SerializeAsync(action); }
        catch (Exception e) { ShowProblem("The note could not be updated", e is ArgumentException or InvalidDataException or InvalidOperationException ? e.Message : "The existing note and draft have been kept. Try again."); }
    }
    private void ShowProblem(string title, string message) { NotesProblem.Title = title; NotesProblem.Message = message; NotesProblem.IsOpen = true; }
    private async Task<bool> Confirm(string title, string message, string primary) => await new ContentDialog { XamlRoot = XamlRoot, Title = title,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
    private void Title_TextChanged(object sender, TextChangedEventArgs e) { if (!loading) { ++editVersion; titleDirty = true; ScheduleSave(); } }
    private void Body_TextChanged(object sender, RoutedEventArgs e) { if (!loading) { ++editVersion; bodyDirty = true; ScheduleSave(); } }
    private void Folder_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (!loading) { ++editVersion; folderDirty = true; ScheduleSave(); } }
    private async void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e) { if (!loading && store is not null) await Run(() => RefreshCoreAsync(library)); }
    private async void Notes_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || e.AddedItems.FirstOrDefault() is not NoteRow row) return;
        await Run(async () => { await SaveCoreAsync(); await WithEditorLockedAsync(async () => { var note = await store.FindAsync(library.Workspace, row.Id); await ShowAsync(note); UpdateLayout(); }); });
    }
    private async void NewNote_Click(object sender, RoutedEventArgs e) => await Run(CreateNoteCoreAsync);
    private async void SaveNote_Click(object sender, RoutedEventArgs e) => await Run(SaveCoreAsync);
    private async void PinNote_Click(object sender, RoutedEventArgs e)
    { bool pinned = PinNoteButton.IsChecked == true; await Run(() => MetadataAsync(n => n with { Pinned = pinned })); }
    private async void RestoreNote_Click(object sender, RoutedEventArgs e) => await Run(() => MetadataAsync(n => n with { DeletedAt = null }));
    private async Task TrashSelectedCoreAsync()
    {
        await SaveCoreAsync(); if (draft is not { } current || current.Document.DeletedAt is not null) return;
        await WithEditorLockedAsync(async () =>
        {
            if (recordingWorkspace == library.Workspace && recordingNoteId == current.Document.Id) await StopRecordingAsync();
            await store.SaveAsync(library.Workspace, current.Digest, current.Document with { DeletedAt = NoteDocument.Now, UpdatedAt = NoteDocument.Now });
            await ShowAsync(null); await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
        });
    }
    private async void TrashNote_Click(object sender, RoutedEventArgs e) => await Run(TrashSelectedCoreAsync);
    private async void Notes_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Delete) { e.Handled = true; await Run(TrashSelectedCoreAsync); } }
    private void Title_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Enter) { e.Handled = true; NoteBody.Focus(FocusState.Programmatic); } }
    private void Format_Click(object sender, RoutedEventArgs e)
    {
        if (loading || NoteBody.IsReadOnly || !NoteEditorScroll.IsEnabled) return;
        try { editor.Format((string)((AppBarButton)sender).Tag); ++editVersion; bodyDirty = true; ScheduleSave(); }
        catch (Exception) { ShowProblem("Formatting unavailable", "Select an editable part of the note and try again."); }
    }
    private async void InsertLink_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        var input = new TextBox { Header = "URL", Text = "https://" };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Insert link", Content = input, PrimaryButtonText = "Insert", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) { editor.Link(input.Text.Trim()); ++editVersion; bodyDirty = true; ScheduleSave(); }
    });
    private async void InsertImage_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        string workspace = library.Workspace; string? noteId = draft?.Document.Id;
        var anchor = NoteBody.Document.Selection.GetClone();
        var picker = new FileOpenPicker(); foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".bmp" }) picker.FileTypeFilter.Add(ext);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        if ((await file.GetBasicPropertiesAsync()).Size > 20 * 1024 * 1024) throw new InvalidDataException("Choose an image smaller than 20 MiB.");
        using var stream = await file.OpenReadAsync(); byte[] png = await SharedNoteEditor.PngAsync(stream);
        if (workspace != library.Workspace || noteId != draft?.Document.Id) throw new InvalidOperationException("The selected note changed before the image was ready.");
        await RunEditorAsync(() => editor.InsertImageAsync(png, target: anchor)); ++editVersion; bodyDirty = true; ScheduleSave();
    });
    private async void Body_Paste(object sender, TextControlPasteEventArgs e)
    {
        if (NoteBody.IsReadOnly || loading) { e.Handled = true; return; }
        var clipboard = Clipboard.GetContent();
        bool rtf = clipboard.Contains(StandardDataFormats.Rtf), bitmap = clipboard.Contains(StandardDataFormats.Bitmap);
        if (!rtf && !bitmap && !clipboard.Contains(StandardDataFormats.Text)) return;
        e.Handled = true; string workspace = library.Workspace; string? noteId = draft?.Document.Id;
        var anchor = NoteBody.Document.Selection.GetClone();
        await Run(async () =>
        {
            if (rtf || !bitmap)
            {
                string text = rtf ? await clipboard.GetRtfAsync() : await clipboard.GetTextAsync();
                if (text.Length > NoteCodec.MaxBytes) throw new InvalidDataException("This clipboard content is too large.");
                if (workspace != library.Workspace || noteId != draft?.Document.Id) throw new InvalidOperationException("The selected note changed before the pasted content was ready.");
                editor.PasteText(text, rtf, anchor);
            }
            else
            {
                var reference = await clipboard.GetBitmapAsync(); using var stream = await reference.OpenReadAsync();
                byte[] png = await SharedNoteEditor.PngAsync(stream);
                if (workspace != library.Workspace || noteId != draft?.Document.Id) throw new InvalidOperationException("The selected note changed before the pasted image was ready.");
                await RunEditorAsync(() => editor.InsertImageAsync(png, target: anchor));
            }
            ++editVersion; bodyDirty = true; ScheduleSave();
        });
    }
    private void Body_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || NoteBody.IsReadOnly) return;
        var selected = NoteBody.Document.Selection; if (selected.StartPosition != selected.EndPosition) return;
        var paragraph = NoteBody.Document.GetRange(selected.StartPosition, selected.StartPosition); paragraph.Expand(TextRangeUnit.Paragraph); paragraph.GetText(TextGetOptions.NoHidden, out string text);
        var match = System.Text.RegularExpressions.Regex.Match(text.TrimEnd('\r', '\n'), @"^(\s*)([•☐☑]|\d+\.) (.*)$");
        if (!match.Success) return;
        string marker = match.Groups[2].Value; if (marker == "☑") marker = "☐";
        if (int.TryParse(marker.TrimEnd('.'), out int n) && n < int.MaxValue) marker = (n + 1) + ".";
        if (match.Groups[3].Value.Length == 0) paragraph.SetText(TextSetOptions.None, "\r");
        else selected.SetText(TextSetOptions.None, "\r" + match.Groups[1].Value + marker + " ");
        e.Handled = true; ++editVersion; bodyDirty = true; ScheduleSave();
    }
    private void Body_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (NoteBody.IsReadOnly) return;
        var range = NoteBody.Document.GetRangeFromPoint(e.GetCurrentPoint(NoteBody).Position, PointOptions.ClientCoordinates);
        NoteBody.Document.GetText(TextGetOptions.AllowFinalEop, out string native);
        if (range.StartPosition >= native.Length - 1) return;
        range.SetRange(range.StartPosition, range.StartPosition + 1); range.GetText(TextGetOptions.NoHidden, out string text);
        if (text is "☐" or "☑") { range.SetText(TextSetOptions.None, text == "☐" ? "☑" : "☐"); e.Handled = true; ++editVersion; bodyDirty = true; ScheduleSave(); }
    }
    private async void ExportNotes_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        await SaveCoreAsync(); var picker = new FileSavePicker { SuggestedFileName = "Takt-notes-" + DateTime.Today.ToString("yyyy-MM-dd") };
        picker.FileTypeChoices.Add("Takt notes", new List<string> { ".json" }); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
        if (await picker.PickSaveFileAsync() is { } file) await FileIO.WriteTextAsync(file, NoteBackup.Export(await store.ReadAsync(library.Workspace)));
    });
    private async void ImportNotes_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        await SaveCoreAsync(); if (library.Profile is not null) throw new InvalidOperationException("Sign out to import notes into the local library.");
        var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".json"); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        if ((await file.GetBasicPropertiesAsync()).Size > 64 * 1024 * 1024) throw new InvalidDataException("Note backup exceeds 64 MiB.");
        await store.ImportAsync("local", NoteBackup.Import(await FileIO.ReadTextAsync(file), library)); await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
    });
    private async void UploadLocalNotes_Click(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        await SaveCoreAsync(); if (library.Profile is null) throw new InvalidOperationException("Sign in before importing local notes into an account.");
        var local = await store.ReadAsync("local"); var notes = local.Notes.Where(n => n.Document.DeletedAt is null && !n.Document.IsPurged).Select(n => n.Document with { Folder = "inbox" }).ToList();
        if (!await Confirm("Copy local notes to this account?", $"Add {notes.Count} notes as new copies? Existing cloud notes and the local originals will be kept.", "Copy notes")) return;
        await store.ImportAsync(library.Workspace, notes); await RefreshCoreAsync(library); Changed?.Invoke(this, EventArgs.Empty);
    });
    private void Notes_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        if (section == "notes:trash") { e.Cancel = true; return; }
        e.Data.SetData(DragFormat, JsonSerializer.Serialize(new { workspace = library.Workspace, ids = e.Items.Cast<NoteRow>().Select(n => n.Id).ToArray() })); e.Data.RequestedOperation = DataPackageOperation.Move;
    }
    private void FolderTasks_Click(object sender, RoutedEventArgs e) => TasksRequested?.Invoke(this, EventArgs.Empty);
    private async void Back_Click(object sender, RoutedEventArgs e) => await Run(async () => { await SaveCoreAsync(); await ShowAsync(null); UpdateLayout(); });
    private void Workspace_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateLayout();
    private void UpdateLayout()
    {
        if (Columns is null) return; bool narrow = ActualWidth < 720;
        NoteListPane.Visibility = narrow && draft is not null ? Visibility.Collapsed : Visibility.Visible;
        NoteDetailPane.Visibility = narrow && draft is null ? Visibility.Collapsed : Visibility.Visible;
        NotesBack.Visibility = narrow && draft is not null ? Visibility.Visible : Visibility.Collapsed;
        NoteResize.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible; NoteSplitterColumn.Width = new(narrow ? 0 : 16);
        NoteListColumn.MinWidth = narrow ? 0 : 260; NoteEditorColumn.MinWidth = narrow ? 0 : 300;
        NoteListColumn.Width = narrow ? new(1, GridUnitType.Star) : new(listWidth); NoteEditorColumn.Width = narrow ? new(0) : new(1, GridUnitType.Star);
        Grid.SetColumn(NoteDetailPane, narrow ? 0 : 2); Grid.SetColumnSpan(NoteDetailPane, narrow ? 3 : 1); Grid.SetColumnSpan(NoteListPane, narrow ? 3 : 1);
    }
    private void Resize_Started(object sender, DragStartedEventArgs e) => listWidth = NoteListColumn.ActualWidth;
    private void Resize_Delta(object sender, DragDeltaEventArgs e) { listWidth = Math.Clamp(listWidth + e.HorizontalChange, 260, Math.Max(260, ActualWidth - 340)); UpdateLayout(); }
    private void Resize_KeyDown(object sender, KeyRoutedEventArgs e)
    { if (e.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Home) { listWidth = e.Key == VirtualKey.Home ? 350 : Math.Clamp(listWidth + (e.Key == VirtualKey.Left ? -16 : 16), 260, Math.Max(260, ActualWidth - 340)); UpdateLayout(); e.Handled = true; } }
    private async Task RunEditorAsync(Func<Task> action)
    {
        if (!editingOperation.IsCompleted) throw new InvalidOperationException("Wait for the image to finish loading.");
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); editingOperation = completed.Task;
        try { await action(); }
        finally { completed.TrySetResult(); editingOperation = Task.CompletedTask; }
    }
    public void EnsureCanLeave()
    {
        EnsureNotRecording();
        if (transcribing is not null) throw new InvalidOperationException("Pause transcription before switching libraries or closing Takt.");
        if (operations.CurrentCount == 0) throw new InvalidOperationException("Wait for the current note operation to finish.");
        if (!editingOperation.IsCompleted || !presentation.IsCompleted) throw new InvalidOperationException("Wait for the note editor to finish loading.");
    }
    private void EnsureNotRecording() { if (IsRecording) throw new InvalidOperationException("Stop recording before switching libraries or closing Takt."); }
}
