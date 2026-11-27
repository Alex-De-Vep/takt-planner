using System.Diagnostics;
using Takt.Core.Models;

namespace Takt.Core.Sync;

public sealed partial class CloudSync
{
    public async Task RunChangeFeedAsync(Profile profile, Action signal, CancellationToken cancellation)
    {
        int delay = 2;
        while (!cancellation.IsCancellationRequested)
        {
            string? token = null;
            long started = Stopwatch.GetTimestamp();
            int retry = delay;
            try
            {
                bool taskEvents;
                await network.WaitAsync(cancellation).ConfigureAwait(false);
                try
                {
                    if (await store.ConnectionAsync().ConfigureAwait(false) is not { Credential: not null } current ||
                        current.Profile != profile) return;

                    CheckRateLimit();
                    await Configure(profile.Origin, cancellation).ConfigureAwait(false);
                    if (capabilities?.NoteEventsVersion != 1) return;
                    taskEvents = capabilities.TaskEventsVersion == 1;
                    token = await Access(profile, cancellation).ConfigureAwait(false);
                }
                finally { network.Release(); }

                await api.WatchChangesAsync(profile.Origin, token, taskEvents, signal, cancellation).ConfigureAwait(false);
            }
            catch (ApiException error) when (error.Status is 404 or 405 || error.Code == "incompatible_protocol")
            { return; }
            catch (NotSupportedException) { return; }
            catch (ApiException error) when (error.Status == 401)
            {
                if (token is null) return;
                await network.WaitAsync(cancellation).ConfigureAwait(false);
                try
                {
                    if (access is { } cached && cached.Profile == profile && cached.Token == token)
                        access = null;
                }
                finally { network.Release(); }
            }
            catch (ApiException error)
            {
                if (error.RetryAfter is > 0)
                {
                    retry = (int)Math.Clamp(error.RetryAfter.Value, delay, 86400);
                    await network.WaitAsync(cancellation).ConfigureAwait(false);
                    try { RateLimit(error); }
                    finally { network.Release(); }
                }
            }
            catch (Exception error) when (error is HttpRequestException or IOException or InvalidDataException or TimeoutException ||
                error is OperationCanceledException && !cancellation.IsCancellationRequested)
            {
                // Polling remains active during stream reconnects.
            }

            if (Stopwatch.GetElapsedTime(started) > TimeSpan.FromSeconds(30)) delay = 2;
            else delay = Math.Min(delay * 2, 60);
            await Task.Delay(TimeSpan.FromSeconds(retry), cancellation).ConfigureAwait(false);
        }
    }
}
