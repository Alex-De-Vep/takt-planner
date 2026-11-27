using System.IO.Compression;
using System.Text;
using System.Text.Json;
using NAudio.Wave;
using Takt.Core.Assistant;
using Takt.Core.Calendar;
using Takt.Core.Models;
using Takt.Core.Notes;
using Takt.Core.Storage;

namespace Takt.Windows.Services;

internal static class LibraryArchive
{
    private const string Format = "takt.windows.library";
    private const string ManifestPath = "library.json";
    private const int MaxManifestBytes = 128 * 1024 * 1024;
    private const long MaxArchiveBytes = 1024L * 1024 * 1024;
    private const int MaxEntries = 5000;
    private const int MaxRecordingBytes = 100 * 1024 * 1024;
    private const int MaxTranscriptBytes = 4 * 1024 * 1024;

    private sealed record Manifest(string Format, int Version, DateTimeOffset CreatedAt, TaskBackup Tasks,
        List<NoteDocument> Notes, CalendarSnapshot Calendar, ChatThread[] History);

    public static async Task ExportAsync(string path, Library library, NotesState notes,
        CalendarSnapshot calendar, IReadOnlyList<ChatThread> history, CancellationToken cancellation)
    {
        if (notes.Workspace != library.Workspace || history.Any(thread => thread.Workspace != library.Workspace))
            throw new InvalidOperationException("The library changed while preparing the backup.");

        var taskIds = library.Tasks.Select(task => task.Id).ToHashSet(StringComparer.Ordinal);
        var entities = library.Live.Where(entity => entity.Type is "task" or "folder" ||
            entity.Type == "checklistItem" && entity.Text("taskId") is { } parent && taskIds.Contains(parent))
            .Select(entity => entity with { Versions = [], Revision = "0" }).ToList();
        var taskBackup = new TaskBackup(1, Wire.Time(), entities);
        _ = TaskBackup.Plan(taskBackup, preserveIds: true);
        var documents = notes.Notes.Select(note => note.Document)
            .Where(note => !note.IsPurged && !note.Expired(NoteDocument.Now)).ToList();
        var snapshot = calendar with { Calendars = calendar.Calendars.Where(item => item.Feed is null).ToArray() };
        var manifest = new Manifest(Format, 1, DateTimeOffset.UtcNow, taskBackup, documents, snapshot,
            history.Select(NormalizeHistory).ToArray());
        var encoded = JsonSerializer.SerializeToUtf8Bytes(manifest, Wire.Json);
        if (encoded.Length > MaxManifestBytes) throw new InvalidDataException("The library data exceeds 128 MiB.");

        string temporary = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, ".takt-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            await using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true))
            {
                using var archive = new ZipArchive(file, ZipArchiveMode.Create, leaveOpen: true);
                await using (var entry = archive.CreateEntry(ManifestPath).Open())
                    await entry.WriteAsync(encoded, cancellation);
                var audio = new NoteAudioLibrary();
                long total = encoded.Length;
                int count = 1;
                foreach (var note in documents)
                foreach (var clip in audio.List(library.Workspace, note.Id))
                {
                    string prefix = $"audio/{Guid.Parse(note.Id):D}/{clip.Id}.wav";
                    await WriteFileAsync(prefix, clip.Path, MaxRecordingBytes);
                    await WriteFileAsync(prefix + ".name.txt", clip.Path + ".name.txt", 1024);
                    await WriteFileAsync(prefix + ".transcript.txt", NoteTranscription.PreviewPath(clip), MaxTranscriptBytes);
                }

                async Task WriteFileAsync(string entryName, string source, int maximum)
                {
                    if (!File.Exists(source)) return;
                    await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true);
                    long length = input.Length;
                    total += length;
                    if (++count > MaxEntries || length > maximum || total > MaxArchiveBytes)
                        throw new InvalidDataException("The backup exceeds the supported recording or archive size.");
                    var entry = archive.CreateEntry(entryName, CompressionLevel.Fastest);
                    entry.LastWriteTime = File.GetLastWriteTimeUtc(source);
                    await using var output = entry.Open();
                    await CopyExactlyAsync(input, output, length, cancellation);
                }
            }
            if (new FileInfo(temporary).Length > MaxArchiveBytes)
                throw new InvalidDataException("The saved archive exceeds 1 GiB.");
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
        }
        finally { DeleteTemporaryFile(temporary); }
    }

    public static async Task<Guid> RestoreAsync(string path, CancellationToken cancellation)
    {
        var id = Guid.NewGuid();
        string final = LibraryDirectories.For(id);
        string staging = final + ".tmp";
        try
        {
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true);
            if (file.Length > MaxArchiveBytes) throw new InvalidDataException("The backup exceeds 1 GiB.");
            using var archive = new ZipArchive(file, ZipArchiveMode.Read);
            if (archive.Entries.Count is 0 or > MaxEntries) throw new InvalidDataException("The backup has an invalid number of entries.");
            var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
            long total = 0;
            foreach (var entry in archive.Entries)
            {
                if (!entries.TryAdd(entry.FullName, entry) || entry.Length > MaxArchiveBytes - total)
                    throw new InvalidDataException("The backup has duplicate entries or exceeds 1 GiB.");
                total += entry.Length;
            }
            if (!entries.Remove(ManifestPath, out var manifestFile) || manifestFile.Length > MaxManifestBytes)
                throw new InvalidDataException("The backup is missing its library data.");

            Manifest manifest;
            await using (var manifestInput = manifestFile.Open())
            {
                using var data = new MemoryStream();
                await CopyExactlyAsync(manifestInput, data, manifestFile.Length, cancellation);
                manifest = JsonSerializer.Deserialize<Manifest>(data.GetBuffer().AsSpan(0, (int)data.Length), Wire.Json)
                    ?? throw new InvalidDataException("The backup has invalid library data.");
            }
            if (manifest.Format != Format || manifest.Version != 1 || manifest.Tasks is null || manifest.Notes is null ||
                manifest.Calendar is null || manifest.History is null || manifest.History.Length > 200 ||
                manifest.Notes.Count > 10000 || manifest.Notes.Any(note => note is null) ||
                manifest.History.Any(thread => thread is null))
                throw new InvalidDataException("Choose a supported Takt Windows library backup.");
            var edits = TaskBackup.Plan(manifest.Tasks, preserveIds: true);
            var folders = edits.Where(e => e.Type == "folder").Select(e => e.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var taskIds = edits.Where(e => e.Type == "task").Select(e => e.Id).ToHashSet(StringComparer.Ordinal);
            foreach (var note in manifest.Notes) NoteCodec.Validate(note);
            var noteIds = manifest.Notes.Select(note => Guid.Parse(note.Id).ToString("D")).ToHashSet(StringComparer.Ordinal);
            if (noteIds.Count != manifest.Notes.Count)
                throw new InvalidDataException("The backup contains duplicate notes.");
            var notesToRestore = manifest.Notes.Select(note => note.FolderId() is { } folder && !folders.Contains(folder)
                ? note with { Folder = "inbox" } : note).ToArray();
            var survivingNoteIds = notesToRestore.Where(note => !note.IsPurged && !note.Expired(NoteDocument.Now))
                .Select(note => Guid.Parse(note.Id).ToString("D")).ToHashSet(StringComparer.Ordinal);
            var media = new List<(ZipArchiveEntry Entry, string Note, string FileName, bool Expired)>();
            foreach (var (name, entry) in entries)
            {
                string[] segments = name.Split('/');
                if (segments.Length != 3 || segments[0] != "audio" || !noteIds.Contains(segments[1]))
                    throw new InvalidDataException("The backup contains an invalid recording path.");
                string clip = segments[2];
                int extension = clip.IndexOf(".wav", StringComparison.Ordinal);
                string suffix = extension < 0 ? "" : clip[extension..];
                int limit = suffix switch { ".wav" => MaxRecordingBytes, ".wav.name.txt" => 1024, ".wav.transcript.txt" => MaxTranscriptBytes, _ => 0 };
                if (limit == 0 || entry.Length > limit || !Guid.TryParseExact(clip.AsSpan(0, extension), "D", out var clipId) ||
                    clip != clipId.ToString("D") + suffix || !entries.ContainsKey($"audio/{segments[1]}/{clipId:D}.wav"))
                    throw new InvalidDataException("The backup contains an invalid recording.");
                media.Add((entry, segments[1], clip, !survivingNoteIds.Contains(segments[1])));
            }

            Directory.CreateDirectory(staging);
            using (var tasks = new PlannerStore(Path.Combine(staging, "tasks.sqlite"), pooling: false))
            {
                await tasks.InitializeAsync();
                await tasks.EditAsync("local", edits, 0);
            }
            using (var notes = new NoteStore(Path.Combine(staging, "notes.sqlite"), pooling: false))
            {
                await notes.InitializeAsync();
                await notes.RestoreLocalAsync(notesToRestore);
            }
            await using (var calendar = new LocalCalendarProvider(Path.Combine(staging, "calendar.sqlite"), pooling: false))
                await calendar.RestoreLocalAsync(manifest.Calendar, taskIds, cancellation);
            var threads = manifest.History.Select(NormalizeHistory).ToArray();
            if (threads.Select(thread => thread.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != threads.Length)
                throw new InvalidDataException("The backup contains duplicate conversations.");
            using (var chat = new ChatStore(Path.Combine(staging, "assistant.db"), pooling: false))
                foreach (var thread in threads) await chat.SaveAsync(thread);

            foreach (var (entry, note, filename, expired) in media)
            {
                if (expired) continue;
                string directory = NoteAudioLibrary.DirectoryFor(staging, "local", note);
                Directory.CreateDirectory(directory);
                string outputPath = Path.Combine(directory, filename);
                await using (var input = entry.Open())
                await using (var output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, useAsync: true))
                    await CopyExactlyAsync(input, output, entry.Length, cancellation);
                if (filename.EndsWith(".wav", StringComparison.Ordinal))
                {
                    using var wav = new WaveFileReader(outputPath);
                    if (wav.TotalTime <= TimeSpan.Zero || wav.TotalTime > TimeSpan.FromMinutes(31))
                        throw new InvalidDataException("The backup contains an invalid recording duration.");
                }
                else _ = new UTF8Encoding(false, true).GetString(await File.ReadAllBytesAsync(outputPath, cancellation));
                File.SetLastWriteTimeUtc(outputPath, entry.LastWriteTime.UtcDateTime);
            }

            cancellation.ThrowIfCancellationRequested();
            await File.WriteAllTextAsync(Path.Combine(staging, "library-ready"), "1", cancellation);
            Directory.Move(staging, final);
            return id;
        }
        finally
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    private static ChatThread NormalizeHistory(ChatThread thread)
    {
        var normalized = thread with
        {
            Workspace = "local",
            Messages = thread.Messages.Select(message => message with
            {
                Context = message.Context is { } context ? context with { Workspace = "local" } : null
            }).ToArray()
        };
        ChatRules.Thread(normalized);
        return normalized;
    }

    private static async Task CopyExactlyAsync(Stream source, Stream destination, long length, CancellationToken cancellation)
    {
        var buffer = new byte[65536];
        long remaining = length;
        while (remaining > 0)
        {
            int count = await source.ReadAsync(buffer.AsMemory(0, (int)Math.Min(remaining, buffer.Length)), cancellation);
            if (count == 0) throw new InvalidDataException("The backup contains an incomplete entry.");
            await destination.WriteAsync(buffer.AsMemory(0, count), cancellation);
            remaining -= count;
        }
        if (await source.ReadAsync(buffer.AsMemory(0, 1), cancellation) != 0)
            throw new InvalidDataException("The backup contains an entry with an invalid length.");
    }

    private static void DeleteTemporaryFile(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
