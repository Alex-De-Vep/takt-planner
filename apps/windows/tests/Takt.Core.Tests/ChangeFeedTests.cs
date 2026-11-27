using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Takt.Core.Sync;
using Xunit;

namespace Takt.Core.Tests;

public sealed class ChangeFeedTests
{
    [Fact]
    public async Task ChangeSignalsWaitForACompleteFrameAndIgnoreUnadvertisedTaskSignals()
    {
        const string events = ": keep-alive\r\n\r\n" +
            "event: ready\r\ndata: {}\r\n\r\n" +
            "event: tasks.changed\ndata: {}\n\n" +
            "event: notes.changed\ndata: {}\n\n" +
            "event: notes.changed\ndata: {}\n";
        using var http = new HttpClient(new FeedHandler(events));
        var client = new ApiClient(http);
        int signals = 0;
        await client.WatchChangesAsync("https://fixture.invalid", "fixture", tasks: false, () => signals++, CancellationToken.None);
        Assert.Equal(2, signals);
        signals = 0;
        await client.WatchChangesAsync("https://fixture.invalid", "fixture", tasks: true, () => signals++, CancellationToken.None);
        Assert.Equal(3, signals);
    }

    [Fact]
    public async Task OversizedFrameFailsWithoutSignalling()
    {
        using var http = new HttpClient(new FeedHandler("event: notes.changed\ndata: " + new string('x', 4096)));
        var client = new ApiClient(http);
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            client.WatchChangesAsync("https://fixture.invalid", "fixture", tasks: true, () => throw new Exception("Unexpected signal."), CancellationToken.None));
    }

    private sealed class FeedHandler(string events) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal("/v1/notes/events", request.RequestUri!.AbsolutePath);
            Assert.Equal("fixture", request.Headers.Authorization?.Parameter);
            var content = new StreamContent(new ByteStream(Encoding.UTF8.GetBytes(events)));
            content.Headers.ContentType = new MediaTypeHeaderValue("text/event-stream");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        }
    }

    private sealed class ByteStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            => base.ReadAsync(buffer[..Math.Min(buffer.Length, 1)], cancellationToken);
    }
}
