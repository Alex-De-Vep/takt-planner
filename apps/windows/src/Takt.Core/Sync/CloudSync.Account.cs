using System.Text;

namespace Takt.Core.Sync;

public enum EmailAccountAction { Register, Verify, ResetPassword }

public sealed partial class CloudSync
{
    private sealed record ChallengeReply(string ChallengeId);
    private sealed record AccountActionReply(bool Ok);

    public async Task<string> RequestEmailCodeAsync(string origin, string email, EmailAccountAction action,
        string? password, CancellationToken cancellation = default)
    {
        origin = ApiClient.NormalizeOrigin(origin);
        email = email.Trim();
        if (email.Length is 0 or > 254 || email.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)))
            throw new ArgumentException("Enter a valid email address.");

        string path = action switch
        {
            EmailAccountAction.Register => "/v1/auth/register",
            EmailAccountAction.Verify => "/v1/auth/resend-verification",
            EmailAccountAction.ResetPassword => "/v1/auth/password-reset/request",
            _ => throw new ArgumentOutOfRangeException(nameof(action))
        };
        object body = new { email };
        if (action == EmailAccountAction.Register)
        {
            ValidateAccountPassword(password);
            body = new { email, password };
        }

        await network.WaitAsync(cancellation);
        try
        {
            CheckRateLimit();
            var result = await api.SendAsync<ChallengeReply>(origin, path, body, cancellation: cancellation);
            if (!Guid.TryParseExact(result.ChallengeId, "D", out var challenge))
                throw new InvalidDataException("The server did not return a valid email challenge.");
            return challenge.ToString("D");
        }
        catch (ApiException error) { RateLimit(error); throw; }
        finally { network.Release(); }
    }

    public async Task ConfirmEmailCodeAsync(string origin, string challengeId, string code, string password,
        EmailAccountAction action, CancellationToken cancellation = default)
    {
        origin = ApiClient.NormalizeOrigin(origin);
        if (code.Length != 8 || !code.All(char.IsAsciiDigit) || !Guid.TryParseExact(challengeId, "D", out var challenge))
            throw new ArgumentException("Enter the eight-digit code from your email.");
        ValidateAccountPassword(password);

        bool reset = action == EmailAccountAction.ResetPassword;
        if (!reset && action is not (EmailAccountAction.Register or EmailAccountAction.Verify))
            throw new ArgumentOutOfRangeException(nameof(action));

        challengeId = challenge.ToString("D");
        object body = reset ? new { challengeId, code, newPassword = password } : new { challengeId, code, password };
        string path = reset ? "/v1/auth/password-reset/confirm" : "/v1/auth/verify-email";

        await network.WaitAsync(cancellation);
        try
        {
            CheckRateLimit();
            var result = await api.SendAsync<AccountActionReply>(origin, path, body, cancellation: cancellation);
            if (!result.Ok) throw new InvalidDataException("The server did not confirm the account change.");
        }
        catch (ApiException error) { RateLimit(error); throw; }
        finally { network.Release(); }
    }

    private static void ValidateAccountPassword(string? password)
    {
        if (password is null || password.Contains('\0') || password.EnumerateRunes().Count() is < 12 or > 128)
            throw new ArgumentException("Use a password of 12 to 128 characters.");
    }
}
