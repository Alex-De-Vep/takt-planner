namespace Takt.Windows.Services;

internal static class LibraryDirectories
{
    private static readonly Lazy<string> Current = new(ReadActiveDirectory);
    public static string Root { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Takt", "Windows");
    public static string Restored => Path.Combine(Root, "restored-libraries");
    public static string Active => Current.Value;
    private static string Pointer => Path.Combine(Root, "active-library.txt");

    private static string ReadActiveDirectory()
    {
        try
        {
            var file = new FileInfo(Pointer);
            if (!file.Exists || file.Length > 64) return Root;
            return Guid.TryParseExact(File.ReadAllText(file.FullName).Trim(), "D", out var id) &&
                IsRestored(id) ? For(id) : Root;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return Root; }
    }

    public static string For(Guid id) => Path.Combine(Restored, id.ToString("D"));
    private static bool IsRestored(Guid id) => File.Exists(Path.Combine(For(id), "library-ready"));
    public static Guid[] List() => !Directory.Exists(Restored) ? [] :
        Directory.EnumerateDirectories(Restored).Select(path =>
            Guid.TryParseExact(Path.GetFileName(path), "D", out var id) && IsRestored(id) ? id : (Guid?)null)
            .OfType<Guid>().OrderByDescending(id => Directory.GetCreationTime(For(id))).ToArray();

    public static void SelectOnNextLaunch(Guid? id)
    {
        Directory.CreateDirectory(Root);
        if (id is not null && !IsRestored(id.Value)) throw new InvalidOperationException("This restored library is unavailable.");
        File.WriteAllText(Pointer + ".tmp", id?.ToString("D") ?? "");
        File.Move(Pointer + ".tmp", Pointer, overwrite: true);
    }
}
