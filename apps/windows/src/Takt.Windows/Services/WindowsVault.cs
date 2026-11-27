using System.Security.Cryptography;
using System.Text;
using Takt.Core.Sync;

namespace Takt.Windows.Services;

public sealed class WindowsVault : ICredentialVault
{
    public string Seal(string scope, string plaintext) => Convert.ToBase64String(ProtectedData.Protect(
        Encoding.UTF8.GetBytes(plaintext), SHA256.HashData(Encoding.UTF8.GetBytes(scope)), DataProtectionScope.CurrentUser));
    public string Open(string scope, string ciphertext) => Encoding.UTF8.GetString(ProtectedData.Unprotect(
        Convert.FromBase64String(ciphertext), SHA256.HashData(Encoding.UTF8.GetBytes(scope)), DataProtectionScope.CurrentUser));
}
