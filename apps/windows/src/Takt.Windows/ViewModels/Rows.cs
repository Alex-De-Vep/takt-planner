using Microsoft.UI.Xaml;
using Takt.Core.Models;

namespace Takt.Windows.ViewModels;

public sealed record FolderChoice(string Key, string Name);
public sealed class TaskRow(Entity entity, Library library)
{
    public string Id => entity.Id;
    public string Title => string.IsNullOrWhiteSpace(entity.Text("title")) ? "Untitled task" : entity.Text("title")!;
    public bool Completed => entity.Completed;
    public bool Focused => entity.Focused(DateOnly.FromDateTime(DateTime.Now));
    public string Folder => library.Folders.FirstOrDefault(f => f.Id == library.Location(entity))?.Text("name") ?? (library.Location(entity) switch
    { "week" => "This Week", "month" => "Month", _ => "Inbox" });
    public string DeadlineLabel => entity.Deadline is { } d ? FormatDeadline(d) : "";
    public Visibility DeadlineVisibility => entity.Deadline is null ? Visibility.Collapsed : Visibility.Visible;
    public string Progress => library.Items(Id).Any() ? $"{library.Items(Id).Count(i => i.Flag("isCompleted"))}/{library.Items(Id).Count()}" : "";
    public string Subtitle => string.Join(" · ", new[] { Folder, Progress }.Where(s => s.Length > 0));
    public static string FormatDeadline(Deadline d)
    {
        var (date, time) = d.LocalParts();
        return date.ToString("d MMM") + (time is null ? "" : " · " + time.Value.ToString("t"));
    }
}
public sealed record ChecklistRow(string Id, string Title, bool Completed);
