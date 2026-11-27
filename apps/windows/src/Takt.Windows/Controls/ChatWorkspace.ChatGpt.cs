using Takt.Core.Assistant;
using Takt.Windows.Services;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace
{
    private readonly ChatGptOAuth chatGpt = new();

    private static string ChatGptHostId()
    {
        string path = Path.Combine(LibraryDirectories.Root, "chatgpt-host.txt");
        if (File.Exists(path))
        {
            var info = new FileInfo(path);
            if (info.Length <= 64 && Guid.TryParseExact(File.ReadAllText(path).Trim(), "D", out var saved))
                return "urn:uuid:" + saved.ToString("D");
            throw new InvalidDataException("The saved ChatGPT host registration is invalid.");
        }
        Directory.CreateDirectory(LibraryDirectories.Root);
        var id = Guid.NewGuid().ToString("D");
        File.WriteAllText(path + ".tmp", id);
        File.Move(path + ".tmp", path);
        return "urn:uuid:" + id;
    }

    private async Task<string> ConnectionKeyAsync(SavedChatConnection saved, CancellationToken cancellation)
    {
        if (saved.Connection.Provider != "chatgpt") return saved.Key();

        // The picker holds its original item until the next settings refresh.
        // Read the latest credential record after a successful token rotation.
        saved = settings.Connections.FirstOrDefault(item => item.Id == saved.Id && item.Connection.Provider == "chatgpt")
            ?? throw new ReviewFailure("This ChatGPT connection was removed.");
        var credential = saved.ChatGpt();
        if (credential.Expires > DateTimeOffset.UtcNow.AddSeconds(60)) return credential.AccessToken;
        cancellation.ThrowIfCancellationRequested();
        // Finish a bounded token rotation and commit it even if the chat generation is stopped.
        ChatGptCredential updated;
        try { updated = await chatGpt.RefreshAsync(credential, CancellationToken.None); }
        catch (InvalidOperationException error) { throw new ReviewFailure(error.Message); }
        var replacement = saved.WithChatGpt(updated);
        var next = settings with { Connections = settings.Connections.Select(item => item.Id == saved.Id ? replacement : item).ToArray() };
        next.Save(directory);
        settings = next;
        cancellation.ThrowIfCancellationRequested();
        return updated.AccessToken;
    }
}
