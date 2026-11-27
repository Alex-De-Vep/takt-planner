using Microsoft.UI.Xaml;
using System.Text;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.System;
using global::Windows.UI.Core;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer taskAutosave = new() { Interval = TimeSpan.FromMilliseconds(750) };
    private readonly SemaphoreSlim itemCreationGate = new(1, 1);
    private readonly SemaphoreSlim taskSaveGate = new(1, 1);
    private void InitializeTaskAutosave()
    {
        TaskTitle.TextChanged += (_, _) => QueueTaskAutosave();
        Description.TextChanged += (_, _) => QueueTaskAutosave();
        Location.SelectionChanged += (_, _) => QueueTaskAutosave();
        taskAutosave.Tick += async (_, _) =>
        {
            taskAutosave.Stop();
            if (!ready || closing || showingNotes || draft is null || string.IsNullOrWhiteSpace(TaskTitle.Text)) return;
            await Guard(SaveEditorAsync);
        };
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.S, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, async () =>
        {
            if (!showingNotes && draft is { } task && library.Tasks.FirstOrDefault(t => t.Id == task.Id) is { } current)
                await ChangeFocus(task.Id, !current.Focused(currentDay));
        }, () => !showingNotes && FocusWithin(WorkspaceGrid)));
    }
    private void QueueTaskAutosave()
    {
        if (!ready || rendering || closing || showingNotes || draft is null) return;
        taskAutosave.Stop(); taskAutosave.Start();
    }
    private async void CopyTask_Click(object sender, RoutedEventArgs e) => await Guard(() =>
    {
        if (draft is null || showingNotes) return Task.CompletedTask;
        var text = new StringBuilder(TaskTitle.Text.Trim());
        if (Description.Text.Length > 0) text.AppendLine().AppendLine().Append(Description.Text);
        foreach (var item in ChecklistItems) text.AppendLine().Append(item.Completed ? "[x] " : "[ ] ").Append(item.Title);
        var package = new DataPackage(); package.SetText(text.ToString()); Clipboard.SetContent(package);
        return Task.CompletedTask;
    });
    private bool FocusWithin(DependencyObject ancestor)
    {
        var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject;
        while (focused is not null)
        {
            if (ReferenceEquals(focused, ancestor)) return true;
            focused = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(focused);
        }
        return false;
    }
    private bool FocusInDialog()
    {
        var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject;
        while (focused is not null)
        {
            if (focused is Microsoft.UI.Xaml.Controls.ContentDialog) return true;
            focused = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(focused);
        }
        return false;
    }
    private static bool AltPressed() =>
        (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu) & CoreVirtualKeyStates.Down) != 0;
    private static bool ShiftPressed() =>
        (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
}
