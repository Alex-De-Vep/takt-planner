using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Takt.Core.Assistant;

public sealed partial class ChatClient
{
    private sealed record SseEvent(string Name, string Data);
    // Read bounded bytes instead of StreamReader.ReadLineAsync, whose line allocation is unbounded.
    private static async IAsyncEnumerable<SseEvent> Events(Stream stream, [EnumeratorCancellation] CancellationToken cancellation)
    {
        byte[] buffer = new byte[8192]; using var line = new MemoryStream(); StringBuilder data = new();
        var utf8 = new UTF8Encoding(false, true); string name = ""; int total = 0; bool first = true, previousCr = false;
        while (true)
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellation); idle.CancelAfter(TimeSpan.FromSeconds(45));
            int count;
            try { count = await stream.ReadAsync(buffer, idle.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new TimeoutException("The AI response stream stopped responding."); }
            if (count == 0)
            {
                if (line.Length != 0 || data.Length != 0) throw new InvalidDataException("The AI response ended in an incomplete event. No changes were applied.");
                yield break;
            }
            total += count; if (total > MaxResponseBytes) throw new InvalidDataException("The AI response exceeds 4 MiB.");
            for (int i = 0; i < count; ++i)
            {
                byte next = buffer[i];
                if (next == 10 && previousCr) { previousCr = false; continue; }
                previousCr = next == 13;
                if (next is not (10 or 13))
                {
                    if (line.Length >= 512 * 1024) throw new InvalidDataException("An AI stream line exceeds its size limit.");
                    line.WriteByte(next); continue;
                }
                string value;
                try { value = utf8.GetString(line.ToArray()).TrimEnd('\r'); }
                catch (DecoderFallbackException error) { throw new InvalidDataException("The AI stream contains invalid Unicode.", error); }
                line.SetLength(0); line.Position = 0;
                if (first) { value = value.TrimStart('\uFEFF'); first = false; }
                if (value.Length == 0)
                {
                    if (data.Length > 0) { yield return new(name, data.ToString(0, data.Length - 1)); data.Clear(); }
                    name = ""; continue;
                }
                if (value[0] == ':') continue;
                int colon = value.IndexOf(':'); string field = colon < 0 ? value : value[..colon];
                string fieldValue = colon < 0 ? "" : value[(colon + 1)..]; if (fieldValue.StartsWith(' ')) fieldValue = fieldValue[1..];
                if (field == "data") { data.Append(fieldValue).Append('\n'); if (data.Length > 1024 * 1024) throw new InvalidDataException("An AI stream event exceeds its size limit."); }
                else if (field == "event") { if (fieldValue.Length > 128) throw new InvalidDataException("Invalid AI stream event name."); name = fieldValue; }
            }
        }
    }
    private sealed record ChangeInput([property: JsonRequired] string Kind, string? Title = null, string? Text = null,
        string[]? Subtasks = null, string? Date = null, string? Time = null, bool? ClearDate = null,
        bool? Today = null, bool? Completed = null, string? Start = null, string? End = null, bool? AllDay = null, string? Location = null);
    private sealed record ChangeSet([property: JsonRequired] string Message, [property: JsonRequired] ChangeInput[] Changes);
    private sealed class ToolBuffer
    {
        public string Name = "";
        public StringBuilder Arguments { get; } = new();
        public string? InitialInput;
        public void Append(string value)
        {
            if (Arguments.Length + value.Length > 512 * 1024) throw new InvalidDataException("A proposed change exceeds its size limit.");
            Arguments.Append(value);
        }
    }
    private sealed class ReplyAccumulator(bool anthropic, bool toolsEnabled, ChatContext context, IProgress<string>? progress, bool giga = false)
    {
        private readonly StringBuilder text = new();
        private readonly SortedDictionary<int, ToolBuffer> calls = [];
        private readonly Dictionary<int, (string Type, bool Closed)> blocks = [];
        private string? finishReason;
        private bool terminal, started;
        private long lastProgress;
        private int reportedLength;
        public bool Event(SseEvent item)
        {
            if (terminal) throw new InvalidDataException("Unexpected data after the AI response finished.");
            if (item.Name == "error") throw new InvalidOperationException("The AI service reported a streaming error. Retry when ready; no changes were applied.");
            if (item.Data == "[DONE]")
            {
                if (anthropic) throw new InvalidDataException("Unexpected Anthropic stream marker.");
                terminal = true; return true;
            }
            using var json = JsonDocument.Parse(item.Data, new JsonDocumentOptions { MaxDepth = 32 });
            if (json.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid AI stream event.");
            if (json.RootElement.TryGetProperty("error", out _)) throw new InvalidOperationException("The AI service reported a streaming error. No changes were applied.");
            if (anthropic) Anthropic(json.RootElement); else OpenAi(json.RootElement);
            return terminal;
        }
        public void Full(byte[] bytes)
        {
            using var json = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 }); var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.TryGetProperty("error", out _)) throw new InvalidDataException("Invalid AI response.");
            if (anthropic)
            {
                finishReason = String(root, "stop_reason");
                if (!root.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid Anthropic response content.");
                int index = 0;
                foreach (var block in content.EnumerateArray())
                {
                    string kind = String(block, "type") ?? "";
                    if (kind == "text") Append(String(block, "text") ?? "");
                    else if (kind == "tool_use")
                    {
                        var tool = NewTool(index); tool.Name = String(block, "name") ?? "";
                        if (!block.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid proposed change input.");
                        tool.InitialInput = input.EnumerateObject().Any() ? input.GetRawText() : "{}";
                    }
                    ++index;
                }
            }
            else
            {
                if (!root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() != 1) throw new InvalidDataException("Expected one AI completion.");
                var choice = choices[0]; finishReason = String(choice, "finish_reason");
                if (!choice.TryGetProperty("message", out var message)) throw new InvalidDataException("Invalid AI completion message.");
                Append(String(message, "content") ?? String(message, "refusal") ?? "");
                if (giga && message.TryGetProperty("function_call", out var nativeCall) && nativeCall.ValueKind == JsonValueKind.Object)
                {
                    var tool = NewTool(0);
                    tool.Name = String(nativeCall, "name") ?? "";
                    if (!nativeCall.TryGetProperty("arguments", out var arguments))
                        throw new InvalidDataException("Invalid GigaChat function arguments.");
                    tool.Append(arguments.ValueKind == JsonValueKind.Object ? arguments.GetRawText() : arguments.GetString() ?? "");
                    if (finishReason == "function_call") finishReason = "tool_calls";
                }
                if (message.TryGetProperty("tool_calls", out var tools) && tools.ValueKind != JsonValueKind.Null)
                {
                    if (tools.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid AI tool calls.");
                    int index = 0; foreach (var call in tools.EnumerateArray())
                    {
                        if (String(call, "type") != "function" || !call.TryGetProperty("function", out var function)) throw new InvalidDataException("Unsupported AI tool call.");
                        var tool = NewTool(index++); tool.Name = String(function, "name") ?? ""; tool.Append(String(function, "arguments") ?? "");
                    }
                }
            }
            terminal = true;
        }
        private void OpenAi(JsonElement root)
        {
            if (!root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid AI completion chunk.");
            foreach (var choice in choices.EnumerateArray())
            {
                if (Index(choice) != 0) throw new InvalidDataException("Expected one streamed AI completion.");
                if (choice.TryGetProperty("delta", out var delta))
                {
                    string part = String(delta, "content") ?? String(delta, "refusal") ?? "";
                    if (finishReason is not null && part.Length != 0) throw new InvalidDataException("Unexpected AI text after completion.");
                    Append(part);
                    if (delta.TryGetProperty("tool_calls", out var tools) && tools.ValueKind != JsonValueKind.Null)
                    {
                        if (finishReason is not null || tools.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid streamed tool calls.");
                        foreach (var call in tools.EnumerateArray())
                        {
                            int index = Index(call); if (!calls.TryGetValue(index, out var tool)) tool = NewTool(index);
                            if (String(call, "type") is { } type && type != "function") throw new InvalidDataException("Unsupported AI tool call.");
                            if (call.TryGetProperty("function", out var function))
                            {
                                tool.Name += String(function, "name") ?? ""; if (tool.Name.Length > 128) throw new InvalidDataException("Invalid AI tool name.");
                                tool.Append(String(function, "arguments") ?? "");
                            }
                        }
                    }
                }
                if (String(choice, "finish_reason") is { } reason)
                {
                    if (finishReason is not null && finishReason != reason) throw new InvalidDataException("Inconsistent AI completion reason.");
                    finishReason = reason;
                }
            }
        }
        private void Anthropic(JsonElement root)
        {
            switch (String(root, "type"))
            {
                case "message_start": if (started) throw new InvalidDataException("Duplicate AI message start."); started = true; break;
                case "content_block_start":
                {
                    int index = Index(root); if (!started || blocks.ContainsKey(index) || blocks.Count >= 128 || !root.TryGetProperty("content_block", out var block)) throw new InvalidDataException("Invalid AI content block.");
                    string kind = String(block, "type") ?? ""; blocks.Add(index, (kind, false));
                    if (kind == "text") Append(String(block, "text") ?? "");
                    else if (kind == "tool_use")
                    {
                        var tool = NewTool(index); tool.Name = String(block, "name") ?? "";
                        if (!block.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid AI tool input.");
                        tool.InitialInput = input.EnumerateObject().Any() ? input.GetRawText() : "{}";
                    }
                    break;
                }
                case "content_block_delta":
                {
                    int index = Index(root);
                    if (!blocks.TryGetValue(index, out var block) || block.Closed || !root.TryGetProperty("delta", out var delta)) throw new InvalidDataException("Invalid AI content delta.");
                    string kind = String(delta, "type") ?? "";
                    if (kind == "text_delta") { if (block.Type != "text") throw new InvalidDataException("Mismatched AI text block."); Append(String(delta, "text") ?? ""); }
                    else if (kind == "input_json_delta")
                    {
                        if (block.Type != "tool_use" || !calls.TryGetValue(index, out var tool) || tool.InitialInput != "{}") throw new InvalidDataException("Mismatched AI tool block.");
                        tool.Append(String(delta, "partial_json") ?? "");
                    }
                    // Thinking/signatures and future non-action block types are intentionally not exposed as answers.
                    break;
                }
                case "content_block_stop":
                {
                    int index = Index(root); if (!blocks.TryGetValue(index, out var block) || block.Closed) throw new InvalidDataException("Invalid AI content stop.");
                    blocks[index] = (block.Type, true); break;
                }
                case "message_delta":
                    if (root.TryGetProperty("delta", out var update) && String(update, "stop_reason") is { } reason) finishReason = reason;
                    break;
                case "message_stop":
                    if (!started || blocks.Values.Any(b => !b.Closed)) throw new InvalidDataException("The AI stream contains incomplete blocks.");
                    terminal = true; break;
                case "error": throw new InvalidOperationException("The AI service reported a streaming error. No changes were applied.");
            }
        }
        public ChatReply Reply()
        {
            if (!terminal || (anthropic ? finishReason is not ("end_turn" or "tool_use" or "stop_sequence") : finishReason is not ("stop" or "tool_calls")))
                throw new InvalidDataException("The AI response did not finish completely. No changes were applied.");
            if (calls.Count != 0 && (anthropic ? finishReason != "tool_use" : finishReason != "tool_calls")) throw new InvalidDataException("The AI proposal stream did not finish completely.");
            List<ChatProposal> proposals = [];
            foreach (var tool in calls.Values)
            {
                if (!toolsEnabled || tool.Name != "propose_changes") throw new InvalidDataException("The AI returned an unsupported tool. No changes were applied.");
                string arguments = tool.Arguments.Length > 0 ? tool.Arguments.ToString() : tool.InitialInput ?? "";
                using (var json = JsonDocument.Parse(arguments, new JsonDocumentOptions { MaxDepth = 32 })) RejectDuplicateProperties(json.RootElement);
                var changes = JsonSerializer.Deserialize<ChangeSet>(arguments, StrictJson) ?? throw new InvalidDataException("Invalid proposed changes.");
                ChatRules.Text(changes.Message, ChatRules.MaxTextBytes);
                if (changes.Changes is null || changes.Changes.Length > ChatRules.MaxProposals || proposals.Count + changes.Changes.Length > ChatRules.MaxProposals) throw new InvalidDataException("Too many proposed changes.");
                foreach (var change in changes.Changes)
                {
                    if (change is null) throw new InvalidDataException("Invalid proposed change.");
                    var proposal = new ChatProposal(Guid.NewGuid().ToString("D"), change.Kind, change.Title, change.Text, change.Subtasks,
                        change.Date, change.Time, change.ClearDate, change.Today, change.Completed, change.Start, change.End, change.AllDay, change.Location);
                    ChatRules.Proposal(proposal, context); proposals.Add(proposal);
                }
                if (changes.Message.Length > 0 && text.ToString() != changes.Message) Append((text.Length == 0 ? "" : "\n\n") + changes.Message);
            }
            if (text.Length == 0 && proposals.Count == 0) throw new InvalidDataException("The AI returned an empty response.");
            ChatRules.Text(text.ToString(), ChatRules.MaxTextBytes); NotifyProgress(true); return new(text.ToString(), proposals.ToArray());
        }
        private ToolBuffer NewTool(int index)
        {
            if (index is < 0 or > 127 || calls.Count >= 4 || calls.ContainsKey(index)) throw new InvalidDataException("Too many or duplicate AI tool calls.");
            var tool = new ToolBuffer(); calls.Add(index, tool); return tool;
        }
        private void Append(string part)
        {
            if (part.Length == 0) return;
            if (text.Length + part.Length > ChatRules.MaxTextBytes) throw new InvalidDataException("The AI answer exceeds its text limit.");
            text.Append(part); NotifyProgress(false);
        }
        private void NotifyProgress(bool final)
        {
            if (progress is null || reportedLength == text.Length) return;
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!final && reportedLength > 0 && System.Diagnostics.Stopwatch.GetElapsedTime(lastProgress, now) < TimeSpan.FromMilliseconds(50)) return;
            reportedLength = text.Length; lastProgress = now; progress.Report(text.ToString());
        }
        private static string? String(JsonElement element, string field)
        {
            if (element.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid AI response object.");
            if (!element.TryGetProperty(field, out var value) || value.ValueKind == JsonValueKind.Null) return null;
            if (value.ValueKind != JsonValueKind.String) throw new InvalidDataException("Invalid AI response field."); return value.GetString();
        }
        private static int Index(JsonElement element) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty("index", out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int index) && index >= 0 && index <= 127
            ? index : throw new InvalidDataException("Invalid AI response index.");
        private static void RejectDuplicateProperties(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Object)
            {
                HashSet<string> names = []; foreach (var property in element.EnumerateObject())
                { if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate proposed change field."); RejectDuplicateProperties(property.Value); }
            }
            else if (element.ValueKind == JsonValueKind.Array) foreach (var value in element.EnumerateArray()) RejectDuplicateProperties(value);
        }
    }
}
