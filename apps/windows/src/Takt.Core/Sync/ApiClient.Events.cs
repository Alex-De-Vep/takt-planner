using System.Net.Http.Headers;
using System.Text;

namespace Takt.Core.Sync;

public sealed partial class ApiClient
{
    public async Task WatchChangesAsync(string origin, string token, bool tasks, Action signal, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, NormalizeOrigin(origin) + "/v1/notes/events");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        idle.CancelAfter(TimeSpan.FromSeconds(35));

        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                var retry = response.Headers.RetryAfter;
                long? seconds = retry?.Delta is { } delay ? (long)Math.Ceiling(delay.TotalSeconds) :
                    retry?.Date is { } date ? (long)Math.Ceiling((date - DateTimeOffset.UtcNow).TotalSeconds) : null;
                throw new ApiException((int)response.StatusCode, "change_feed_unavailable", seconds);
            }
            if (!string.Equals(response.Content.Headers.ContentType?.MediaType, "text/event-stream", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The server returned an invalid change stream.");

            await using var input = await response.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false);
            var buffer = new byte[4096];
            var line = new byte[4096];
            int length = 0, frameBytes = 0;
            string? name = null;
            bool hasData = false;
            while (true)
            {
                int count = await input.ReadAsync(buffer, idle.Token).ConfigureAwait(false);
                if (count == 0) break;
                idle.CancelAfter(TimeSpan.FromSeconds(35));
                bool changed = false;
                for (int i = 0; i < count; i++)
                {
                    if (++frameBytes > 8192) throw new InvalidDataException("The change stream frame is too large.");
                    if (buffer[i] != (byte)'\n')
                    {
                        if (length == line.Length) throw new InvalidDataException("The change stream line is too large.");
                        line[length++] = buffer[i];
                        continue;
                    }
                    int contentLength = length > 0 && line[length - 1] == (byte)'\r' ? length - 1 : length;
                    if (contentLength == 0)
                    {
                        changed |= hasData && (name is "ready" or "notes.changed" || tasks && name == "tasks.changed");
                        name = null;
                        hasData = false;
                        frameBytes = 0;
                    }
                    else
                    {
                        string field = Encoding.UTF8.GetString(line, 0, contentLength);
                        if (field.StartsWith("event:", StringComparison.Ordinal)) name = field[6..].TrimStart(' ');
                        else if (field.StartsWith("data:", StringComparison.Ordinal)) hasData = true;
                    }
                    length = 0;
                }
                if (changed)
                {
                    cancellation.ThrowIfCancellationRequested();
                    signal();
                }
            }
        }
        catch (OperationCanceledException error) when (!cancellation.IsCancellationRequested && idle.IsCancellationRequested)
        {
            throw new TimeoutException("The server stopped sending change signals.", error);
        }
    }
}
