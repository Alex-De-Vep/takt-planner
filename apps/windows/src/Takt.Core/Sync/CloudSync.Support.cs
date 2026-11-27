using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Sync;

public sealed record SupportRequest(string SubmissionId, string? Subject, string Message, string? ReplyEmail,
    string Platform, string AppVersion, string AppBuild, string OsVersion, DateTimeOffset DeviceTime)
{
    public void ValidatePayload()
    {
        ValidateContent(Subject, Message, ReplyEmail);
        if (JsonSerializer.SerializeToUtf8Bytes(this, Wire.Json).Length > 32768)
            throw new ArgumentException("This request exceeds the server size limit. Shorten the message and try again.");
    }

    public static void ValidateContent(string? subject, string message, string? replyEmail)
    {
        if (string.IsNullOrWhiteSpace(message) || message.Contains('\0') || message.EnumerateRunes().Count() > 4000)
            throw new ArgumentException("Enter a message of 1 to 4,000 characters.");
        if (subject is not null && (string.IsNullOrWhiteSpace(subject) ||
            subject.EnumerateRunes().Count() > 120 || subject.Any(char.IsControl)))
            throw new ArgumentException("Use at most 120 characters for the subject.");
        if (replyEmail is not null && (replyEmail.Length > 254 ||
            !Regex.IsMatch(replyEmail, """^[^\s@,;<>"\x00-\x1f\x7f]+@[^\s@,;<>"\x00-\x1f\x7f]+\.[^\s@,;<>"\x00-\x1f\x7f]+$""")))
            throw new ArgumentException("Enter a single reply email address.");
    }
}

public sealed record SupportReceipt(string Code, DateTimeOffset ReceivedAt);

public sealed partial class CloudSync
{
    public async Task<SupportReceipt> SubmitSupportAsync(Profile profile, SupportRequest request,
        CancellationToken cancellation = default)
    {
        request.ValidatePayload();
        if (!Guid.TryParseExact(request.SubmissionId, "D", out var id) || id.ToString("D") != request.SubmissionId)
            throw new ArgumentException("The support request has an invalid identifier.");

        await network.WaitAsync(cancellation);
        try
        {
            CheckRateLimit();
            if ((await store.ConnectionAsync())?.Profile != profile)
                throw new InvalidOperationException("Sign in to the account that owns this support request.");
            var receipt = await Authorized<SupportReceipt>(profile, "/v1/support/requests", request, cancellation);
            if (receipt.Code is not { Length: >= 11 and <= 24 } ||
                !receipt.Code.StartsWith("TAKT-", StringComparison.Ordinal) ||
                !receipt.Code[5..].All(char.IsAsciiDigit) || receipt.ReceivedAt == default)
                throw new InvalidDataException("The server did not return a valid receipt. Retry to recover the request code.");
            return receipt;
        }
        catch (ApiException error) { RateLimit(error); throw; }
        finally { network.Release(); }
    }
}
