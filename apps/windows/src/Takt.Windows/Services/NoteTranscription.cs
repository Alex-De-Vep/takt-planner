using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text;
using NAudio.Wave;

namespace Takt.Windows.Services;

public sealed record TranscriptionSettings(string Endpoint = "", string Model = "", string? Credential = null)
{
    private static string PathName => Path.Combine(Preferences.DirectoryPath, "transcription.json");
    public static TranscriptionSettings Read() => File.Exists(PathName) ? JsonSerializer.Deserialize<TranscriptionSettings>(File.ReadAllText(PathName)) ?? new() : new();
    public void Save()
    {
        _ = Address(Endpoint);
        if (string.IsNullOrWhiteSpace(Model) || Model.Length > 512 || Model.Any(char.IsControl)) throw new ArgumentException("Choose a transcription model.");
        Directory.CreateDirectory(Preferences.DirectoryPath);
        File.WriteAllText(PathName + ".tmp", JsonSerializer.Serialize(this)); File.Move(PathName + ".tmp", PathName, true);
    }
    public static Uri Address(string address)
    {
        if (!Uri.TryCreate(address.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new ArgumentException("Enter the full HTTPS URL of an OpenAI-compatible audio/transcriptions endpoint.");
        return uri;
    }
}
public sealed record TranscriptionProgress(int Completed, int Total, int Current);
public sealed class TranscriptionSegmentException(int index, int total, Exception inner)
    : Exception($"Segment {index + 1} of {total} could not be transcribed. Completed parts are saved on this device.", inner)
{
    public int Index { get; } = index;
}
public static class NoteTranscription
{
    // A journal is specific to the audio bytes, destination and model. Resuming
    // sends only unfinished parts; neither cancellation nor a failed upload erases
    // a provider response already committed to disk.
    private sealed record Journal(int Version, string AudioHash, string Endpoint, string Model, List<string?> Parts, HashSet<int> Skipped);
    private static string JournalPath(NoteAudioClip clip) => clip.Path + ".transcription.json";
    public static string PreviewPath(NoteAudioClip clip) => clip.Path + ".transcript.txt";
    public static void ResetProgress(NoteAudioClip clip) => File.Delete(JournalPath(clip));
    public static bool HasPreview(NoteAudioClip clip) => File.Exists(PreviewPath(clip));
    public static string ReadPreview(NoteAudioClip clip)
    {
        var info = new FileInfo(PreviewPath(clip));
        if (info.Length > 4 * 1024 * 1024) throw new InvalidDataException("The saved transcript is too large to review.");
        return File.ReadAllText(info.FullName);
    }
    public static async Task SavePreviewAsync(NoteAudioClip clip, string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 4 * 1024 * 1024) throw new InvalidDataException("The transcript exceeds the 4 MiB local preview limit.");
        string path = PreviewPath(clip), temporary = path + ".tmp";
        await File.WriteAllTextAsync(temporary, text); File.Move(temporary, path, true);
    }
    private static async Task SaveJournalAsync(NoteAudioClip clip, Journal journal)
    {
        string path = JournalPath(clip), temporary = path + ".tmp";
        // Intentionally independent of the upload cancellation token: finish the
        // local commit even if Cancel is pressed after a successful response.
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(journal)); File.Move(temporary, path, true);
    }
    private static async Task<Journal> ReadJournalAsync(NoteAudioClip clip, TranscriptionSettings settings, int count, CancellationToken ct)
    {
        await using var file = File.OpenRead(clip.Path);
        string hash = Convert.ToHexString(await SHA256.HashDataAsync(file, ct));
        string endpoint = TranscriptionSettings.Address(settings.Endpoint).AbsoluteUri;
        if (File.Exists(JournalPath(clip)))
        {
            if (new FileInfo(JournalPath(clip)).Length > 16 * 1024 * 1024) throw new InvalidDataException("The saved transcription progress is too large.");
            var saved = JsonSerializer.Deserialize<Journal>(await File.ReadAllTextAsync(JournalPath(clip), ct)) ?? throw new InvalidDataException("The saved transcription progress could not be read.");
            if (saved.Version == 1 && saved.AudioHash == hash && saved.Endpoint == endpoint && saved.Model == settings.Model && saved.Parts?.Count == count && saved.Skipped is not null && saved.Skipped.All(i => i >= 0 && i < count)) return saved;
            throw new InvalidOperationException("Saved progress belongs to different audio or transcription settings. Keep those settings to resume, or export the recording and start a separate transcription.");
        }
        return new(1, hash, endpoint, settings.Model, Enumerable.Repeat<string?>(null, count).ToList(), []);
    }
    private static (int Bytes, int Count) Layout(WaveFileReader reader)
    {
        var format = reader.WaveFormat;
        if (format.Encoding != WaveFormatEncoding.Pcm || format.BitsPerSample != 16 || format.Channels is < 1 or > 2 || format.SampleRate is < 8000 or > 48000 || reader.TotalTime > TimeSpan.FromHours(2))
            throw new InvalidDataException("Transcription requires a mono or stereo PCM16 WAV recording of at most two hours.");
        int bytes = checked(format.AverageBytesPerSecond * 120);
        return (bytes, checked((int)((reader.Length + bytes - 1) / bytes)));
    }
    public static async Task SkipSegmentAsync(NoteAudioClip clip, TranscriptionSettings settings, int index, CancellationToken ct)
    {
        using var reader = new WaveFileReader(clip.Path); var layout = Layout(reader);
        var saved = await ReadJournalAsync(clip, settings, layout.Count, ct);
        if (index < 0 || index >= saved.Parts.Count) throw new ArgumentOutOfRangeException(nameof(index));
        saved.Skipped.Add(index); await SaveJournalAsync(clip, saved);
        await SavePreviewAsync(clip, Joined(saved));
    }
    private static string Joined(Journal saved) => string.Join("\n", saved.Parts.Select((p, i) => saved.Skipped.Contains(i) ? $"[Segment {i + 1} skipped]" : p).Where(p => p is not null)).Trim();
    public static async Task<string> TranscribeAsync(NoteAudioClip clip, TranscriptionSettings settings, CancellationToken ct, IProgress<TranscriptionProgress>? progress = null)
    {
        var endpoint = TranscriptionSettings.Address(settings.Endpoint);
        string? key = settings.Credential is null ? null : new WindowsVault().Open("transcription:" + endpoint.AbsoluteUri, settings.Credential);
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(3) };
        using var reader = new WaveFileReader(clip.Path); var layout = Layout(reader);
        if (layout.Count == 0) throw new InvalidDataException("This recording has no audio to transcribe.");
        var saved = await ReadJournalAsync(clip, settings, layout.Count, ct);
        for (int index = 0; index < layout.Count; ++index)
        {
            ct.ThrowIfCancellationRequested();
            int completed = saved.Parts.Count(p => p is not null) + saved.Skipped.Count(i => saved.Parts[i] is null);
            progress?.Report(new(completed, layout.Count, index + 1));
            if (saved.Parts[index] is not null || saved.Skipped.Contains(index)) continue;
            try
            {
                reader.Position = (long)index * layout.Bytes;
                using var wav = new MemoryStream();
                using (var writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(wav), reader.WaveFormat))
                {
                    byte[] block = new byte[8192]; int remaining = layout.Bytes;
                    while (remaining > 0)
                    {
                        int n = reader.Read(block, 0, Math.Min(block.Length, remaining));
                        if (n == 0) break; writer.Write(block, 0, n); remaining -= n;
                    }
                }
                using var body = new MultipartFormDataContent(); body.Add(new StringContent(settings.Model), "model");
                var audio = new ByteArrayContent(wav.ToArray()); audio.Headers.ContentType = new("audio/wav"); body.Add(audio, "file", $"recording-{index + 1}.wav");
                using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = body };
                if (key is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Transcription failed (HTTP {(int)response.StatusCode}).");
                if (response.Content.Headers.ContentLength > 512 * 1024) throw new InvalidDataException("The transcription response is too large.");
                using var output = new MemoryStream(); await using var input = await response.Content.ReadAsStreamAsync(ct); byte[] bytes = new byte[8192];
                while (true)
                {
                    int n = await input.ReadAsync(bytes, ct); if (n == 0) break;
                    if (output.Length + n > 512 * 1024) throw new InvalidDataException("The transcription response is too large."); output.Write(bytes, 0, n);
                }
                using var json = JsonDocument.Parse(output.ToArray());
                if (!json.RootElement.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String) throw new InvalidDataException("The provider returned no transcription text.");
                saved.Parts[index] = text.GetString()!;
                if (Encoding.UTF8.GetByteCount(Joined(saved)) > 4 * 1024 * 1024) { saved.Parts[index] = null; throw new InvalidDataException("The transcript exceeds the 4 MiB preview limit. Completed parts remain saved."); }
                await SaveJournalAsync(clip, saved); await SavePreviewAsync(clip, Joined(saved));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException or InvalidOperationException or InvalidDataException or JsonException)
            { throw new TranscriptionSegmentException(index, layout.Count, error); }
        }
        ct.ThrowIfCancellationRequested();
        return Joined(saved);
    }
}
