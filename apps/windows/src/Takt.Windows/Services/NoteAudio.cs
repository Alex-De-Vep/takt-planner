using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using System.Security.Cryptography;
using System.Text;
using Takt.Core.Notes;

namespace Takt.Windows.Services;

public sealed record NoteAudioClip(string Id, string Path, TimeSpan Duration, DateTime Created, string Name = "Recording")
{
    public override string ToString() => $"{Name} · {(int)Duration.TotalMinutes:00}:{Duration.Seconds:00} · {Created:g}";
}
public sealed class NoteAudioLibrary
{
    public string DirectoryFor(string workspace, string noteId) => DirectoryFor(Preferences.DirectoryPath, workspace, noteId);
    public static string DirectoryFor(string root, string workspace, string noteId) => System.IO.Path.Combine(root, "note-audio",
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(workspace))).ToLowerInvariant(), Guid.Parse(noteId).ToString("D"));
    public List<NoteAudioClip> List(string workspace, string id)
    {
        string directory = DirectoryFor(workspace, id); if (!Directory.Exists(directory)) return [];
        List<NoteAudioClip> clips = [];
        foreach (string path in Directory.EnumerateFiles(directory, "*.wav"))
        {
            if (!Guid.TryParseExact(System.IO.Path.GetFileNameWithoutExtension(path), "D", out var clipId)) continue;
            try { using var reader = new WaveFileReader(path); clips.Add(new(clipId.ToString("D"), path, reader.TotalTime, File.GetLastWriteTime(path), File.Exists(path + ".name.txt") ? File.ReadAllText(path + ".name.txt") : "Recording")); }
            catch (Exception e) when (e is IOException or FormatException or InvalidDataException) { }
        }
        return clips.OrderBy(c => c.Created).ToList();
    }
    public string NewPath(string workspace, string id)
    { var directory = DirectoryFor(workspace, id); Directory.CreateDirectory(directory); return System.IO.Path.Combine(directory, Guid.NewGuid().ToString("D") + ".wav"); }
    public void Rename(NoteAudioClip clip, string name)
    {
        name = name.Trim();
        if (name.Length is 0 or > 120 || name.Any(char.IsControl)) throw new ArgumentException("Use a recording name of 1–120 characters.");
        File.WriteAllText(clip.Path + ".name.txt.tmp", name); File.Move(clip.Path + ".name.txt.tmp", clip.Path + ".name.txt", true);
    }
    public void Delete(NoteAudioClip clip)
    {
        foreach (string path in Directory.EnumerateFiles(System.IO.Path.GetDirectoryName(clip.Path)!, System.IO.Path.GetFileName(clip.Path) + ".*")) File.Delete(path);
        File.Delete(clip.Path);
    }
    public void Copy(string workspace, string fromId, string toId)
    {
        foreach (var clip in List(workspace, fromId))
        {
            var directory = DirectoryFor(workspace, toId); Directory.CreateDirectory(directory);
            File.Copy(clip.Path, System.IO.Path.Combine(directory, clip.Id + ".wav"), true);
            foreach (string artifact in Directory.EnumerateFiles(System.IO.Path.GetDirectoryName(clip.Path)!, System.IO.Path.GetFileName(clip.Path) + ".*"))
                if (!artifact.EndsWith(".tmp", StringComparison.Ordinal)) File.Copy(artifact, System.IO.Path.Combine(directory, System.IO.Path.GetFileName(artifact)), true);
        }
    }
    public void Purge(string workspace, string id)
    { string directory = DirectoryFor(workspace, id); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}

public sealed class NoteRecorder
{
    private CancellationTokenSource? stop;
    private Task? worker;
    private volatile bool paused;
    public bool IsRecording => worker is { IsCompleted: false };
    public bool IsPaused => paused;
    public Exception? Failure { get; private set; }
    public TimeSpan Duration { get; private set; }
    public void Start(string destination, bool systemAudio)
    {
        if (IsRecording) throw new InvalidOperationException("A recording is already running.");
        if (worker is not null) throw new InvalidOperationException("Finish the previous recording before starting another one.");
        Failure = null; Duration = TimeSpan.Zero; paused = false;
        var cancellation = new CancellationTokenSource(); stop = cancellation;
        worker = Task.Run(async () =>
        {
            var captures = new List<WasapiCapture>(); var buffers = new List<BufferedWaveProvider>();
            string temporary = destination + ".recording";
            try
            {
                var format = WaveFormat.CreateIeeeFloatWaveFormat(24000, 1);
                var mixer = new MixingSampleProvider(format) { ReadFully = true };
                void Add(WasapiCapture capture)
                {
                    captures.Add(capture);
                    var buffer = new BufferedWaveProvider(capture.WaveFormat) { BufferDuration = TimeSpan.FromSeconds(5), DiscardOnBufferOverflow = true, ReadFully = true }; buffers.Add(buffer);
                    capture.DataAvailable += (_, args) => { if (!paused) buffer.AddSamples(args.Buffer, 0, args.BytesRecorded); };
                    capture.RecordingStopped += (_, args) => { if (args.Exception is not null) { Failure = args.Exception; cancellation.Cancel(); } };
                    ISampleProvider sample = buffer.ToSampleProvider();
                    if (sample.WaveFormat.Channels == 2) sample = new StereoToMonoSampleProvider(sample) { LeftVolume = .5f, RightVolume = .5f };
                    if (sample.WaveFormat.Channels != 1) throw new InvalidOperationException("Select a mono or stereo recording device in Windows settings.");
                    if (sample.WaveFormat.SampleRate != 24000) sample = new WdlResamplingSampleProvider(sample, 24000);
                    mixer.AddMixerInput(new VolumeSampleProvider(sample) { Volume = systemAudio ? .5f : 1f });
                }
                Add(new WasapiCapture()); if (systemAudio) Add(new WasapiLoopbackCapture());
                var pcm = new SampleToWaveProvider16(mixer);
                using (var writer = new WaveFileWriter(temporary, pcm.WaveFormat))
                {
                    foreach (var capture in captures) capture.StartRecording();
                    byte[] block = new byte[960]; // 20 ms, 24 kHz mono PCM16.
                    using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(20));
                    while (await timer.WaitForNextTickAsync(cancellation.Token))
                    {
                        if (paused) { foreach (var buffer in buffers) buffer.ClearBuffer(); continue; }
                        int count = pcm.Read(block, 0, block.Length); writer.Write(block, 0, count);
                        Duration = TimeSpan.FromSeconds(writer.Length / (double)pcm.WaveFormat.AverageBytesPerSecond);
                        if (Duration >= TimeSpan.FromMinutes(30)) break;
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { Failure = error; }
            finally
            {
                foreach (var capture in captures)
                {
                    try { capture.StopRecording(); } catch (Exception e) { Failure ??= e; }
                    try { capture.Dispose(); } catch (Exception e) { Failure ??= e; }
                }
                try
                {
                    if (File.Exists(temporary) && new FileInfo(temporary).Length > 44) File.Move(temporary, destination, true);
                    else if (File.Exists(temporary)) File.Delete(temporary);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Failure ??= error; }
            }
        });
    }
    public void TogglePause() { if (!IsRecording) return; paused = !paused; }
    public async Task StopAsync()
    {
        var pending = worker; var cancellation = stop;
        try { cancellation?.Cancel(); if (pending is not null) await pending; }
        finally { cancellation?.Dispose(); if (ReferenceEquals(stop, cancellation)) { stop = null; worker = null; } }
    }
}
