using System.Net;
using System.Text;
using System.Text.Json;
using Takt.Core.Assistant;
using Takt.Core.Calendar;
using Takt.Core.Models;
using Xunit;

namespace Takt.Core.Tests;

public sealed class ExternalConnectionsTests
{
    [Fact]
    public async Task CalendarFeedConvertsWebcalAndReusesProviderETag()
    {
        var address = CalendarFeedClient.ParseAddress("webcal://calendar.example.test/private.ics");
        using var http = new HttpClient(new Fixture(async request =>
        {
            Assert.Equal(Uri.UriSchemeHttps, request.RequestUri!.Scheme);
            Assert.Equal("\"v1\"", Assert.Single(request.Headers.IfNoneMatch).Tag);
            Assert.Null(request.Headers.Authorization);
            await Task.Yield();
            return new(HttpStatusCode.NotModified);
        }));
        var result = await new CalendarFeedClient(http).FetchAsync(address, "\"v1\"", CancellationToken.None);
        Assert.Null(result.CalendarText);
        Assert.Equal("\"v1\"", result.ETag);
    }

    [Fact]
    public async Task CalendarFeedDoesNotForwardPrivateUrlAcrossOrigins()
    {
        int requests = 0;
        using var http = new HttpClient(new Fixture(_ =>
        {
            requests++;
            var response = new HttpResponseMessage(HttpStatusCode.Redirect);
            response.Headers.Location = new Uri("https://other.example.test/private.ics");
            return Task.FromResult(response);
        }));
        await Assert.ThrowsAsync<InvalidOperationException>(() => new CalendarFeedClient(http).FetchAsync(
            new("https://calendar.example.test/private.ics"), null, CancellationToken.None));
        Assert.Equal(1, requests);
    }

    [Fact]
    public async Task ChatGptUsesResponsesAndRejectsAnUnfinishedReply()
    {
        bool complete = true;
        using var http = new HttpClient(new Fixture(async request =>
        {
            Assert.Equal("https://api.openai.com/v1/responses", request.RequestUri!.AbsoluteUri);
            Assert.Equal("access-token-fixture", request.Headers.Authorization?.Parameter);
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            Assert.False(json.RootElement.GetProperty("store").GetBoolean());
            Assert.True(json.RootElement.GetProperty("stream").GetBoolean());
            Assert.Single(json.RootElement.GetProperty("input").EnumerateArray());
            const string delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n";
            const string result = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}\n\n";
            return new(HttpStatusCode.OK) { Content = new StringContent(complete ? delta + result : delta, Encoding.UTF8, "text/event-stream") };
        }));
        var client = new ChatClient(http);
        var context = new ChatContext("local", null, null, null, new DateOnly(2026, 11, 27), "UTC");
        var connection = new ChatConnection("ChatGPT", "https://api.openai.com/v1/", "fixture", false, Provider: "chatgpt");
        ChatMessage[] history = [new(Wire.Id(), "user", "Hello", DateTimeOffset.UtcNow, [])];
        var reply = await client.CompleteAsync(connection, "access-token-fixture", history, context, CancellationToken.None);
        Assert.Equal("Hello", reply.Text);
        complete = false;
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            client.CompleteAsync(connection, "access-token-fixture", history, context, CancellationToken.None));
    }

    [Fact]
    public void YandexModelMustBelongToTheSelectedFolderAndOrigin()
    {
        var connection = new ChatConnection("Yandex Cloud", "https://ai.api.cloud.yandex.net/v1/",
            "gpt://fixture-folder/yandexgpt/latest", Provider: "yandex", ProviderOption: "fixture-folder");
        ChatProvider.Validate(connection, requireModel: true);
        Assert.Throws<ArgumentException>(() => ChatProvider.Validate(connection with { ProviderOption = "another-folder" }, true));
        Assert.Throws<ArgumentException>(() => ChatProvider.Validate(connection with { Address = "https://elsewhere.example.test/v1/" }, true));
    }

    private sealed class Fixture(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
