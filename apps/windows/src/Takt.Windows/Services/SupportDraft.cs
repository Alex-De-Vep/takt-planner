using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Sync;

namespace Takt.Windows.Services;

internal sealed class SupportDraft(string workspace)
{
    private const long MaximumProtectedBytes = 192 * 1024;
    private readonly WindowsVault vault = new();
    private string Scope => "support:" + workspace;
    private string Location => Path.Combine(Preferences.DirectoryPath, "support-" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(workspace))) + ".draft");

    public SupportRequest? Read()
    {
        var file = new FileInfo(Location);
        if (!file.Exists) return null;
        if (file.Length > MaximumProtectedBytes) throw new InvalidDataException("The stored support draft exceeds its size limit.");
        return JsonSerializer.Deserialize<SupportRequest>(vault.Open(Scope, File.ReadAllText(file.FullName)), Wire.Json)
            ?? throw new InvalidDataException("The stored support draft could not be read.");
    }

    public void Save(SupportRequest request)
    {
        Directory.CreateDirectory(Preferences.DirectoryPath);
        string path = Location, temporary = path + ".tmp";
        string protectedDraft = vault.Seal(Scope, JsonSerializer.Serialize(request, Wire.Json));
        File.WriteAllText(temporary, protectedDraft);
        File.Move(temporary, path, overwrite: true);
    }

    public void Clear() => File.Delete(Location);
}
