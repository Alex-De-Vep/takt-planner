using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Assistant;
using Takt.Windows.Services;
using global::Windows.Storage.Pickers;
using WinRT.Interop;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private bool backupBusy;

    private async Task ShowLibraryBackupAsync()
    {
        if (!ready || backupBusy) return;
        var details = new TextBlock
        {
            Text = "Back up the open library, including tasks, notes, recordings, local calendars and chat history. Store the unencrypted archive somewhere private.",
            TextWrapping = TextWrapping.Wrap
        };
        var export = new Button { Content = "Export library backup…" };
        var restore = new Button { Content = "Restore into a separate library…" };
        var choose = new Button { Content = "Choose library for next launch…" };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Library backup",
            Content = new StackPanel { Spacing = 12, Children = { details, export, restore, choose } },
            CloseButtonText = "Close"
        };
        Func<Task>? action = null;
        export.Click += (_, _) => { action = ExportLibraryAsync; dialog.Hide(); };
        restore.Click += (_, _) => { action = RestoreLibraryAsync; dialog.Hide(); };
        choose.Click += (_, _) => { action = ChooseLibraryAsync; dialog.Hide(); };
        await dialog.ShowAsync();
        if (action is not null) await action();
    }

    private async Task ExportLibraryAsync()
    {
        NotesView.EnsureCanLeave();
        var picker = new FileSavePicker { SuggestedFileName = "Takt-library-" + DateTime.Today.ToString("yyyy-MM-dd") };
        picker.FileTypeChoices.Add("Takt Windows library", new List<string> { ".taktbackup" });
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        if (await picker.PickSaveFileAsync() is not { } output) return;
        if (syncing) throw new InvalidOperationException("Wait for synchronization to finish before exporting the library.");
        if (ChatView.IsBusy) throw new InvalidOperationException("Finish the chat operation before exporting the library.");
        NotesView.EnsureCanLeave();
        backupBusy = true;
        try
        {
            await SaveEditorAsync();
            var current = await store.ReadAsync();
            var currentNotes = notesReady ? await notes.ReadAsync(current.Workspace)
                : throw new InvalidOperationException("Open the note library before exporting a full backup.");
            var calendarSnapshot = await calendar.ReadAsync(current.Workspace, lifetime.Token);
            using var history = new ChatStore(Path.Combine(Preferences.DirectoryPath, "assistant.db"));
            var conversations = await history.ListAsync(current.Workspace);
            var token = lifetime.Token;
            await Task.Run(() => LibraryArchive.ExportAsync(output.Path, current, currentNotes, calendarSnapshot, conversations, token), token);
            if (!closing) await BackupStatusAsync("Backup saved", "Your library was saved to " + output.Name + ".");
        }
        finally { backupBusy = false; }
    }

    private async Task RestoreLibraryAsync()
    {
        NotesView.EnsureCanLeave();
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".taktbackup");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFileAsync() is not { } input) return;
        if (!await ConfirmAsync("Restore library?", "Takt creates a separate local library from this file. You can open it after restarting Takt.", "Restore")) return;
        backupBusy = true;
        try
        {
            var token = lifetime.Token;
            var restored = await Task.Run(() => LibraryArchive.RestoreAsync(input.Path, token), token);
            if (closing) return;
            LibraryDirectories.SelectOnNextLaunch(restored);
            await BackupStatusAsync("Library restored", "Restart Takt to open the restored library. To switch back, use Settings → Library backup → Choose library for next launch.");
        }
        finally { backupBusy = false; }
    }

    private sealed record LibraryChoice(Guid? Id, string Label);

    private async Task ChooseLibraryAsync()
    {
        var options = new[] { new LibraryChoice(null, "Default library") }.Concat(LibraryDirectories.List().Select(id =>
            new LibraryChoice(id, $"Restored {Directory.GetCreationTime(LibraryDirectories.For(id)):g} · {id.ToString("N")[..6]}"))).ToArray();
        var list = new ComboBox
        {
            Header = "Library to open after restarting Takt",
            ItemsSource = options,
            DisplayMemberPath = "Label",
            SelectedItem = options.FirstOrDefault(item => item.Id is { } id && LibraryDirectories.For(id) == LibraryDirectories.Active) ?? options[0],
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Choose library",
            Content = list,
            PrimaryButtonText = "Select for next launch",
            CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && list.SelectedItem is LibraryChoice choice)
        {
            LibraryDirectories.SelectOnNextLaunch(choice.Id);
            await BackupStatusAsync("Library selected", "Restart Takt to open " + choice.Label + ".");
        }
    }

    private async Task BackupStatusAsync(string title, string message)
    {
        await new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "Done"
        }.ShowAsync();
    }
}
