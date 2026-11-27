using Microsoft.UI.Xaml;
using Takt.Core.Notes;

namespace Takt.Windows.ViewModels;

public sealed record NoteRow(string Id, string Title, string Preview, string Updated, bool Pinned, string Digest, bool Conflict)
{
    public Visibility PinVisibility => Pinned ? Visibility.Visible : Visibility.Collapsed;
    public static NoteRow From(StoredNote note) => new(note.Document.Id,
        string.IsNullOrWhiteSpace(note.Document.Title) ? "New note" : note.Document.Title.Trim(),
        new string(note.Document.Text.Replace('\uFFFC', ' ').Replace('\n', ' ').Take(180).ToArray()),
        NoteDocument.Date(note.Document.UpdatedAt).ToLocalTime().ToString("d MMM"), note.Document.Pinned, note.Digest, note.ConflictOf is not null);
}
