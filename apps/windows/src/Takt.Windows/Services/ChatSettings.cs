using System.Text.Json;
using System.Text;
using Takt.Core.Assistant;

namespace Takt.Windows.Services;

public sealed record SavedChatConnection(string Id, ChatConnection Connection, string[] Models, string? ProtectedKey = null)
{
    public string DisplayName => Connection.Name;
    public string Key() => ProtectedKey is null ? "" : new WindowsVault().Open(Scope(Id, Connection), ProtectedKey);
    private static string Scope(string id, ChatConnection connection)
    {
        string scope = "assistant:" + Guid.Parse(id).ToString("D") + ":" + ChatClient.Address(connection.Address).AbsoluteUri + ":" + connection.Protocol;
        return connection.Provider == "custom" && connection.ProviderOption is null
            ? scope : scope + ":" + connection.Provider + ":" + connection.ProviderOption;
    }
    public ChatGptCredential ChatGpt()
    {
        if (Connection.Provider != "chatgpt" || ProtectedKey is null)
            throw new InvalidOperationException("Sign in to ChatGPT before using this connection.");
        var saved = JsonSerializer.Deserialize<ChatGptCredential>(Key())
            ?? throw new InvalidDataException("This ChatGPT session needs a new sign-in.");
        if (saved.ClientId != Connection.ProviderOption || !ChatGptOAuth.ValidToken(saved.AccessToken) ||
            !ChatGptOAuth.ValidToken(saved.RefreshToken) || string.IsNullOrEmpty(saved.Subject) ||
            saved.Scope?.Split(' ').Contains("chatgpt.tokens.use.direct") != true)
            throw new InvalidDataException("This ChatGPT session needs a new sign-in.");
        return saved;
    }

    public SavedChatConnection WithChatGpt(ChatGptCredential credential)
    {
        if (Connection.Provider != "chatgpt" || Connection.ProviderOption != credential.ClientId)
            throw new InvalidDataException("This sign-in belongs to another ChatGPT connection.");
        return this with { ProtectedKey = new WindowsVault().Seal(Scope(Id, Connection), JsonSerializer.Serialize(credential)) };
    }

    public static SavedChatConnection CreateChatGpt(string? id, ChatConnection connection, IEnumerable<string> models, ChatGptCredential credential)
        => CreateMetadata(id, connection, models).WithChatGpt(credential);

    public static SavedChatConnection Create(string? id, ChatConnection connection, IEnumerable<string> models, string key)
    {
        if (connection.Provider == "chatgpt") throw new ArgumentException("Use Continue with ChatGPT to connect this account.");
        var entry = CreateMetadata(id, connection, models);
        ChatRules.Text(key, 8192);
        if (key.Any(c => char.IsControl(c) || char.IsWhiteSpace(c))) throw new ArgumentException("The API key is not valid.");
        if ((ChatClient.Address(connection.Address).Scheme == "https" || connection.Provider == "copilot") && key.Length == 0)
            throw new ArgumentException("Enter the key or connection code for this provider.");
        return entry with { ProtectedKey = key.Length == 0 ? null : new WindowsVault().Seal(Scope(entry.Id, entry.Connection), key) };
    }

    private static SavedChatConnection CreateMetadata(string? id, ChatConnection connection, IEnumerable<string> models)
    {
        string identity = id is null ? Guid.NewGuid().ToString("D") : Guid.Parse(id).ToString("D");
        connection = connection with { Address = ChatClient.Address(connection.Address).AbsoluteUri, Name = connection.Name.Trim() };
        var selected = models.Select(m => m.Trim()).Where(m => m.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
        if (connection.Name.Length is 0 or > 120 || connection.Name.Any(char.IsControl)) throw new ArgumentException("Enter a connection name of 1–120 characters.");
        if (selected.Length is 0 or > 100 || selected.Any(m => m.Length > 512 || m.Any(char.IsControl))) throw new ArgumentException("Choose 1–100 model IDs, one per line.");
        ChatRules.Text(connection.Name, 256, true);
        foreach (string model in selected)
        {
            ChatRules.Text(model, 256, true);
            ChatProvider.Validate(connection with { Model = model }, requireModel: true);
        }
        return new(identity, connection with { Model = selected.Contains(connection.Model) ? connection.Model : selected[0] }, selected);
    }
}
public sealed record ChatSettings(SavedChatConnection[] Connections, string? SelectedConnection = null, string? SelectedModel = null)
{
    public static ChatSettings Empty => new([]);
    private static string FileName(string directory) => Path.Combine(directory, "chat-settings.json");
    public static ChatSettings Read(string directory)
    {
        string path = FileName(directory); if (!File.Exists(path)) return Empty;
        if (new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("The chat settings file exceeds its size limit.");
        var value = JsonSerializer.Deserialize<ChatSettings>(File.ReadAllText(path)) ?? throw new InvalidDataException("The chat settings could not be read.");
        if (value.Connections is null || value.Connections.Length > 30) throw new InvalidDataException("The saved connection list is invalid.");
        HashSet<string> ids = [];
        foreach (var item in value.Connections)
        {
            if (item is null || !Guid.TryParseExact(item.Id, "D", out _) || !ids.Add(item.Id) || item.Connection is null || item.Models is null ||
                item.Models.Length is 0 or > 100 || item.Models.Any(m => string.IsNullOrWhiteSpace(m) || m.Length > 512 || m.Any(char.IsControl)) ||
                string.IsNullOrWhiteSpace(item.Connection.Name) || item.Connection.Name.Length > 120 || item.Connection.Name.Any(char.IsControl) ||
                item.Connection.Model is null || item.Connection.Model.Length > 512 || item.ProtectedKey?.Length > 131072 || item.Connection.Protocol is not ("openai" or "anthropic")) throw new InvalidDataException("The saved chat connection is invalid.");
            ChatProvider.Validate(item.Connection, requireModel: true);
        }
        return value;
    }
    public void Save(string directory)
    {
        Directory.CreateDirectory(directory); string path = FileName(directory);
        string json = JsonSerializer.Serialize(this);
        if (Encoding.UTF8.GetByteCount(json) > 1024 * 1024) throw new ArgumentException("The connection settings are full. Remove unused connections or selected models.");
        File.WriteAllText(path + ".tmp", json); File.Move(path + ".tmp", path, true);
    }
}
