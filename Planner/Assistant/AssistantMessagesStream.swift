import Foundation

/// Messages передаёт вызов функции в отдельном блоке. Карточка готова только после message_stop.
struct AssistantMessagesStream {
    let tools: Bool
    private var lines: [String] = []
    private var size = 0
    private var text = ""
    private var arguments = ""
    private var toolIndex: Int?
    private var toolEnded = false
    private var stopReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    init(tools: Bool) { self.tools = tools }

    mutating func consume(_ rawLine: String) throws -> (delta: String?, reply: AssistantCloudCompletion?) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.hasPrefix("data:") {
            let payload = line.dropFirst(5)
            size += payload.utf8.count + 1
            guard size <= 512_000 else { throw AssistantCloudStream.invalid }
            lines.append(String(payload.first == " " ? payload.dropFirst() : payload))
            return (nil, nil)
        }
        guard line.isEmpty, !lines.isEmpty else { return (nil, nil) }
        let payload = lines.joined(separator: "\n")
        lines.removeAll(keepingCapacity: true)
        size = 0
        let event = try JSONDecoder().decode(Event.self, from: Data(payload.utf8))
        switch event.type {
        case "message_start":
            inputTokens = event.message?.usage?.input_tokens
            outputTokens = event.message?.usage?.output_tokens
        case "content_block_start":
            if event.content_block?.type == "tool_use" {
                guard tools, toolIndex == nil, let index = event.index,
                      event.content_block?.name == "propose_changes" else { throw AssistantCloudStream.invalid }
                toolIndex = index
            } else if let delta = event.content_block?.text, !delta.isEmpty {
                return try append(delta)
            }
        case "content_block_delta":
            if let delta = event.delta?.text, !delta.isEmpty { return try append(delta) }
            if let json = event.delta?.partial_json {
                guard toolIndex != nil, toolIndex == event.index, !toolEnded else { throw AssistantCloudStream.invalid }
                arguments += json
                guard arguments.utf8.count <= 120_000 else { throw AssistantCloudStream.invalid }
            }
        case "content_block_stop":
            if toolIndex != nil, toolIndex == event.index { toolEnded = true }
        case "message_delta":
            if let reason = event.delta?.stop_reason { stopReason = reason }
            if let output = event.usage?.output_tokens { outputTokens = output }
        case "message_stop":
            return (nil, try complete())
        case "error":
            throw AssistantCloudStream.incomplete
        default: break
        }
        return (nil, nil)
    }

    private mutating func append(_ delta: String) throws -> (delta: String?, reply: AssistantCloudCompletion?) {
        text += delta
        guard text.utf8.count <= 96_000 else { throw AssistantCloudStream.invalid }
        return (delta, nil)
    }

    private func complete() throws -> AssistantCloudCompletion {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var response: AssistantResponse
        if toolIndex != nil {
            guard stopReason == "tool_use", toolEnded else { throw AssistantCloudStream.incomplete }
            response = try ActionPlanValidator.decode(arguments)
            guard (response.actions ?? []).allSatisfy({ $0.kind == .task && $0.linkTo == nil }) else {
                throw AssistantCloudStream.invalid
            }
            if !message.isEmpty { response.message = message }
        } else {
            guard ["end_turn", "stop_sequence", "refusal"].contains(stopReason ?? ""), !message.isEmpty else {
                throw AssistantCloudStream.incomplete
            }
            response = .init(message: message)
        }
        let counts = [inputTokens, outputTokens].compactMap { $0 }
        let tokens = counts.count == 2 && counts.allSatisfy { (0...Int(Int32.max)).contains($0) } ? counts.reduce(0, +) : nil
        return .init(response: response, usage: .init(tokens: tokens))
    }

    private struct Event: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        struct Message: Decodable { let usage: Usage? }
        struct Block: Decodable {
            let type: String
            let name: String?
            let text: String?
        }
        struct Delta: Decodable {
            let text: String?
            let partial_json: String?
            let stop_reason: String?
        }
        let type: String
        let index: Int?
        let message: Message?
        let content_block: Block?
        let delta: Delta?
        let usage: Usage?
    }
}
