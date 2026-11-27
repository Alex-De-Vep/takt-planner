using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Takt.Core.Models;

namespace Takt.Core.Assistant;

public sealed partial class ChatClient
{
    private async Task<ChatReply> CompleteResponsesAsync(ChatConnection connection, string token, object[] conversation,
        string instructions, ChatContext context, CancellationToken cancellation, IProgress<string>? progress)
    {
        Dictionary<string, object> body = new()
        {
            ["model"] = connection.Model,
            ["input"] = conversation,
            ["instructions"] = instructions,
            ["store"] = false,
            ["stream"] = true
        };
        if (connection.Tools)
            body["tools"] = new[] { new { type = "function", name = "propose_changes", description = ToolDescription, parameters = ToolSchema, strict = false } };

        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(body, Wire.Json);
        if (bytes.Length > MaxRequestBytes) throw new InvalidDataException("This chat request exceeds 2 MiB. Start a new conversation or attach less context.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(4));
        using var request = Request(connection, token, HttpMethod.Post, "responses");
        request.Content = new ByteArrayContent(bytes);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            CheckResponse(response, request.RequestUri!);
            if (response.Content.Headers.ContentType?.MediaType != "text/event-stream")
                throw new InvalidDataException("ChatGPT returned an invalid response stream.");
            await using var content = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            var preview = new StringBuilder();
            long nextUpdate = 0;
            await foreach (var item in Events(content, timeout.Token).ConfigureAwait(false))
            {
                if (item.Data == "[DONE]") break;
                using var json = JsonDocument.Parse(item.Data);
                var root = json.RootElement;
                string? type = ResponseString(root, "type");
                if (type == "response.output_text.delta" || type == "response.refusal.delta")
                {
                    preview.Append(ResponseString(root, "delta"));
                    if (preview.Length > ChatRules.MaxTextBytes) throw new InvalidDataException("The ChatGPT answer exceeds its text limit.");
                    long now = Environment.TickCount64;
                    if (now >= nextUpdate)
                    {
                        progress?.Report(preview.ToString());
                        nextUpdate = now + 40;
                    }
                }
                else if (type == "response.completed")
                {
                    cancellation.ThrowIfCancellationRequested();
                    return ReadCompletedResponse(root.GetProperty("response"), connection, context, progress);
                }
                else if (type is "response.failed" or "response.incomplete" or "error")
                    throw new InvalidDataException("ChatGPT did not finish the reply. Check your model and plan limits.");
            }
            throw new InvalidDataException("The ChatGPT stream ended before completion.");
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        { throw new TimeoutException("ChatGPT did not finish in time."); }
        catch (Exception error) when (error is JsonException or KeyNotFoundException)
        { throw new InvalidDataException("ChatGPT returned an invalid response.", error); }
    }

    private static ChatReply ReadCompletedResponse(JsonElement response, ChatConnection connection,
        ChatContext context, IProgress<string>? progress)
    {
        if (ResponseString(response, "status") != "completed" ||
            !response.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("ChatGPT did not finish the reply.");
        var text = new StringBuilder();
        var calls = new List<object>();
        foreach (var item in output.EnumerateArray())
        {
            switch (ResponseString(item, "type"))
            {
                case "message":
                    if (!item.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array)
                        throw new InvalidDataException("Invalid ChatGPT message.");
                    foreach (var piece in content.EnumerateArray())
                        text.Append(ResponseString(piece, "text") ?? ResponseString(piece, "refusal") ?? "");
                    break;
                case "function_call":
                    calls.Add(new
                    {
                        type = "function",
                        function = new { name = ResponseString(item, "name") ?? "", arguments = ResponseString(item, "arguments") ?? "" }
                    });
                    break;
                case "reasoning":
                    break;
                default:
                    throw new InvalidDataException("ChatGPT returned an unsupported response item.");
            }
        }
        var normalized = new { choices = new[] { new
        {
            finish_reason = calls.Count == 0 ? "stop" : "tool_calls",
            message = new { content = text.ToString(), tool_calls = calls }
        } } };
        var result = new ReplyAccumulator(false, connection.Tools, context, progress);
        result.Full(JsonSerializer.SerializeToUtf8Bytes(normalized, Wire.Json));
        return result.Reply();
    }

    private static string? ResponseString(JsonElement value, string key) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var property) &&
        property.ValueKind == JsonValueKind.String ? property.GetString() : null;
}
