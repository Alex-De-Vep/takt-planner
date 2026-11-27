using System.Net;
using System.Text;
using System.Text.Json;
using Takt.Core.Assistant;
using Takt.Core.Models;
using Xunit;

namespace Takt.Core.Tests;

public sealed class ChatClientTests
{
    private static readonly ChatConnection Connection = new("Fixture", "https://ai.example.test/v1", "manual-model");
    private static ChatContext Context => new("private-workspace", new("private-folder-id", "Work"),
        new("11111111-1111-4111-8111-111111111111", "Task title", "Task body", "private-fingerprint", [], null, false, false),
        new("22222222-2222-4222-8222-222222222222", "Note title", "Note body", "private-digest", true, false), new(2026, 11, 27), "UTC");
    private static ChatMessage[] History => [new(Wire.Id(), "user", "Make a plan", DateTimeOffset.UtcNow, [], Context)];
    private static string Frame(object data) => "data: " + JsonSerializer.Serialize(data) + "\n\n";
    private static string Chunk(string text, string? reason = null) => Frame(new { choices = new[] { new { index = 0, delta = new { content = text }, finish_reason = reason } } });
    private static string ToolFrame(string arguments, bool first = true) => Frame(new { choices = new[] { new { index = 0, delta = new { tool_calls = new[] { new { index = 0, type = "function", function = new { name = first ? "propose_changes" : null, arguments } } } }, finish_reason = (string?)null } } });
    private static string ToolDone(string reason = "tool_calls") => Frame(new { choices = new[] { new { index = 0, delta = new { }, finish_reason = reason } } }) + "data: [DONE]\n\n";
    private static string Arguments(string kind = "task") => JsonSerializer.Serialize(new { message = "Review this", changes = new[] { new { kind, title = "Plan release", text = "Draft description" } } });
    [Theory]
    [InlineData("https://api.example.test", "https://api.example.test/v1/")]
    [InlineData("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/")]
    [InlineData("https://generativelanguage.googleapis.com/v1beta/openai/", "https://generativelanguage.googleapis.com/v1beta/openai/")]
    [InlineData("http://localhost:4000/custom/v1", "http://localhost:4000/custom/v1/")]
    [InlineData("http://127.0.0.1:4000", "http://127.0.0.1:4000/v1/")]
    [InlineData("http://[::1]:4000/v1", "http://[::1]:4000/v1/")]
    public void ExplicitBasePrefixesAndLocalGatewaysArePreserved(string address, string expected) => Assert.Equal(expected, ChatClient.Address(address).AbsoluteUri);
    [Theory]
    [InlineData("http://example.test/v1")] [InlineData("http://localhost.example.test/v1")]
    [InlineData("https://user:secret@example.test/v1")] [InlineData("https://example.test/v1?api_key=secret")]
    [InlineData("https://example.test/v1#secret")] [InlineData("https://example.test/v1/chat/completions")]
    public void UnsafeOrNonBaseAddressesAreRejected(string address) => Assert.Throws<ArgumentException>(() => ChatClient.Address(address));
    [Fact] public async Task StreamedTextReportsTheFullAccumulatedAnswerAndOmitsInternalContextIdentifiers()
    {
        using var handler = new Handler(_ => Sse(Chunk("Hello ") + Chunk("😀", "stop") + "data: [DONE]\n\n", 1)); using var http = new HttpClient(handler);
        List<string> progress = []; var result = await new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default, new InlineProgress(progress.Add));
        Assert.Equal("Hello 😀", result.Text); Assert.Equal(new[] { "Hello ", "Hello 😀" }, progress); Assert.Empty(result.Proposals);
        Assert.Equal("https://ai.example.test/v1/chat/completions", handler.Uri!.AbsoluteUri); Assert.Equal("fixture-key", handler.Authorization);
        foreach (var secret in new[] { "private-workspace", "private-folder-id", "private-fingerprint", "private-digest", Context.Task!.Id, Context.Note!.Id }) Assert.DoesNotContain(secret, handler.Body!);
        Assert.Contains("Task body", handler.Body!); Assert.Contains("Note body", handler.Body!);
    }
    [Fact] public async Task StreamedToolArgumentsProduceReviewOnlyProposalsWithClientGeneratedIdentity()
    {
        string input = Arguments(); int split = input.Length / 2;
        using var handler = new Handler(_ => Sse(ToolFrame(input[..split]) + ToolFrame(input[split..], false) + ToolDone())); using var http = new HttpClient(handler);
        var reply = await new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default);
        var proposal = Assert.Single(reply.Proposals); Assert.Equal("task", proposal.Kind); Assert.Equal("Plan release", proposal.Title); Assert.True(Guid.TryParseExact(proposal.Id, "D", out _));
        Assert.Equal("Review this", reply.Text);
    }
    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task IncompleteAndTokenLimitedStreamsCannotExposeApplicableProposals(bool limited)
    {
        using var handler = new Handler(_ => Sse(ToolFrame(Arguments()) + (limited ? ToolDone("length") : ""))); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default));
    }
    [Fact] public async Task AModelCannotSupplyOrRetargetAProposalIdentifier()
    {
        string input = "{\"message\":\"Review\",\"changes\":[{\"kind\":\"taskEdit\",\"id\":\"other-task\",\"title\":\"Injected target\"}]}";
        using var handler = new Handler(_ => Sse(ToolFrame(input) + ToolDone())); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default));
    }
    [Fact] public async Task TruncatedOrReadOnlyNotesCannotReceiveReplacementProposals()
    {
        var context = Context with { Note = Context.Note! with { Editable = false, Truncated = true } };
        using var handler = new Handler(_ => Sse(ToolFrame(Arguments("noteEdit")) + ToolDone())); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, context, default));
    }
    [Fact] public async Task ToolsDisabledMeansNoProposalCardsEvenIfAServiceReturnsATool()
    {
        using var handler = new Handler(_ => Sse(ToolFrame(Arguments()) + ToolDone())); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection with { Tools = false }, "fixture-key", History, Context, default));
        Assert.DoesNotContain("\"tools\"", handler.Body!);
    }
    [Fact] public async Task CancellationDuringResponseReadingNeverReturnsPartialActions()
    {
        using var cancel = new CancellationTokenSource(); var stream = new CancelStream(Encoding.UTF8.GetBytes(Chunk("Partial")), cancel);
        using var handler = new Handler(_ => new(HttpStatusCode.OK) { Content = new StreamContent(stream) }); using var http = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, cancel.Token));
        Assert.True(stream.WasDisposed);
    }
    [Fact] public async Task AStreamLineIsBoundedBeforeItCanAllocateAnUnboundedString()
    {
        using var handler = new Handler(_ => Sse("data: " + new string('x', 600 * 1024))); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default));
    }
    [Fact] public async Task HttpRedirectsAndServerErrorBodiesDoNotExposeKeys()
    {
        using var handler = new Handler(_ => new(HttpStatusCode.Redirect) { Content = new StringContent("provider-secret fixture-key") }); using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default));
        Assert.DoesNotContain("fixture-key", error.Message); Assert.DoesNotContain("provider-secret", error.Message); Assert.Equal(1, handler.Count);
    }
    [Fact] public async Task ModelCatalogUsesTheChosenEndpointAndManualModelsNeedNoCatalogMembership()
    {
        using var handler = new Handler(_ => new(HttpStatusCode.OK) { Content = new StringContent("{\"data\":[{\"id\":\"manual-model\"},{\"id\":\"another-model\"}]}", Encoding.UTF8, "application/json") }); using var http = new HttpClient(handler);
        var models = await new ChatClient(http).ModelsAsync(Connection, "fixture-key", default);
        Assert.Equal(new[] { "another-model", "manual-model" }, models); Assert.EndsWith("/v1/models", handler.Uri!.AbsoluteUri);
    }
    [Fact] public async Task AnthropicStreamsUseMessagesDialectAndCompletedToolBlocks()
    {
        string input = Arguments("note");
        string sse = Frame(new { type = "message_start", message = new { } }) +
            Frame(new { type = "content_block_start", index = 0, content_block = new { type = "tool_use", name = "propose_changes", input = new { } } }) +
            Frame(new { type = "content_block_delta", index = 0, delta = new { type = "input_json_delta", partial_json = input } }) +
            Frame(new { type = "content_block_stop", index = 0 }) + Frame(new { type = "message_delta", delta = new { stop_reason = "tool_use" } }) + Frame(new { type = "message_stop" });
        using var handler = new Handler(_ => Sse(sse)); using var http = new HttpClient(handler);
        var reply = await new ChatClient(http).CompleteAsync(Connection with { Protocol = "anthropic", Address = "https://api.anthropic.com" }, "fixture-key", History, Context, default);
        Assert.Equal("note", Assert.Single(reply.Proposals).Kind); Assert.EndsWith("/v1/messages", handler.Uri!.AbsoluteUri); Assert.Equal("fixture-key", handler.ApiKey);
        Assert.Equal("2023-06-01", handler.Version); Assert.Contains("\"input_schema\"", handler.Body!); Assert.Contains("\"system\"", handler.Body!);
    }
    [Fact] public async Task MissingTaskContextAndOversizedEditableContextsAreRejected()
    {
        using var handler = new Handler(_ => Sse(ToolFrame(Arguments("taskEdit")) + ToolDone())); using var http = new HttpClient(handler);
        var client = new ChatClient(http);
        await Assert.ThrowsAsync<InvalidDataException>(() => client.CompleteAsync(Connection, "fixture-key", History, Context with { Task = null }, default));
        await Assert.ThrowsAsync<InvalidDataException>(() => client.CompleteAsync(Connection, "fixture-key", History, Context with { Task = Context.Task! with { Text = new string('x', ChatRules.MaxTextBytes + 1) } }, default));
    }
    [Fact] public async Task CarriageReturnAndMultilineSseFramingAreAccepted()
    {
        string sse = "data: {\rdata: \"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":\"stop\"}]}\r\rdata: [DONE]\r\r";
        using var handler = new Handler(_ => Sse(sse, 1)); using var http = new HttpClient(handler);
        Assert.Equal("Hello", (await new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default)).Text);
    }
    [Fact] public async Task DuplicateChangeFieldsAndUnclosedAnthropicToolsNeverReturnCards()
    {
        string input = "{\"message\":\"Review\",\"changes\":[{\"kind\":\"task\",\"title\":\"One\",\"title\":\"Two\"}]}";
        using var handler = new Handler(_ => Sse(ToolFrame(input) + ToolDone())); using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default));
        string unclosed = Frame(new { type = "message_start" }) + Frame(new { type = "content_block_start", index = 0, content_block = new { type = "tool_use", name = "propose_changes", input = new { } } }) + Frame(new { type = "message_delta", delta = new { stop_reason = "tool_use" } }) + Frame(new { type = "message_stop" });
        using var otherHandler = new Handler(_ => Sse(unclosed)); using var otherHttp = new HttpClient(otherHandler);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ChatClient(otherHttp).CompleteAsync(Connection with { Protocol = "anthropic" }, "fixture-key", History, Context, default));
    }
    [Fact] public async Task CompatibleNonStreamingJsonRepliesUseTheSameProposalValidation()
    {
        string json = JsonSerializer.Serialize(new { choices = new[] { new { message = new { content = "A complete answer" }, finish_reason = "stop" } } });
        using var handler = new Handler(_ => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") }); using var http = new HttpClient(handler);
        Assert.Equal("A complete answer", (await new ChatClient(http).CompleteAsync(Connection, "fixture-key", History, Context, default)).Text);
    }
    private static HttpResponseMessage Sse(string data, int chunk = int.MaxValue)
    {
        var content = new StreamContent(new ChunkStream(Encoding.UTF8.GetBytes(data), chunk)); content.Headers.ContentType = new("text/event-stream"); return new(HttpStatusCode.OK) { Content = content };
    }
    private sealed class InlineProgress(Action<string> changed) : IProgress<string> { public void Report(string value) => changed(value); }
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        public Uri? Uri; public string? Body, Authorization, ApiKey, Version; public int Count;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            ++Count; Uri = request.RequestUri; Body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            Authorization = request.Headers.Authorization?.Parameter;
            ApiKey = request.Headers.TryGetValues("x-api-key", out var keys) ? keys.Single() : null; Version = request.Headers.TryGetValues("anthropic-version", out var versions) ? versions.Single() : null;
            var result = response(request); result.RequestMessage = request; return result;
        }
    }
    private class ChunkStream(byte[] data, int chunk) : MemoryStream(data)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => base.ReadAsync(buffer[..Math.Min(chunk, buffer.Length)], cancellationToken);
    }
    private sealed class CancelStream(byte[] data, CancellationTokenSource cancel) : ChunkStream(data, int.MaxValue)
    {
        public bool WasDisposed;
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (Position == Length) cancel.Cancel(); return base.ReadAsync(buffer, cancellationToken);
        }
        protected override void Dispose(bool disposing) { WasDisposed = true; base.Dispose(disposing); }
    }
}
