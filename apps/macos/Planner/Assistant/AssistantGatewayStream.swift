import Foundation

/// Предложение появляется только после штатного завершения потока и проверки аргументов.
struct AssistantGatewayStream {
    let tools: Bool
    let legacyFunctions: Bool
    let objectArguments: Bool
    private(set) var tokens: Int? = nil
    private var lines: [String] = []
    private var eventBytes = 0
    private var text = ""
    private var arguments = ""
    private var toolName = ""
    private var receivedTool = false
    private var finishReason: String?
    private var refused = false

    init(tools: Bool, legacyFunctions: Bool = false, objectArguments: Bool = false) {
        self.tools = tools
        self.legacyFunctions = legacyFunctions
        self.objectArguments = objectArguments
    }

    mutating func consume(_ rawLine: String) throws -> (delta: String?, reply: AssistantResponse?) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            eventBytes += value.utf8.count + 1
            guard eventBytes <= 512_000 else { throw AssistantCloudStream.invalid }
            lines.append(String(value.first == " " ? value.dropFirst() : value))
            return (nil, nil)
        }
        guard line.isEmpty, !lines.isEmpty else { return (nil, nil) }
        let payload = lines.joined(separator: "\n")
        lines.removeAll(keepingCapacity: true)
        eventBytes = 0
        if payload == "[DONE]" { return (nil, try complete()) }
        let data = Data(payload.utf8)
        let chunk = try Self.decodeChunk(data, objectArguments: objectArguments)
        if chunk.error != nil { throw AssistantCloudStream.incomplete }
        if let count = chunk.usage?.total_tokens, (0...Int(Int32.max)).contains(count) { tokens = count }
        guard let choice = chunk.choices?.first else { return (nil, nil) }
        guard chunk.choices?.count == 1, choice.index == 0 else { throw AssistantCloudStream.invalid }
        let delta = (choice.delta?.content ?? "") + (choice.delta?.refusal ?? "")
        if let finishReason {
            // OpenRouter повторяет причину завершения в последнем кадре с расходом.
            guard chunk.usage != nil, choice.finish_reason == finishReason,
                  delta.isEmpty, choice.delta?.tool_calls?.isEmpty != false else { throw AssistantCloudStream.invalid }
            return (nil, nil)
        }
        if choice.delta?.refusal?.isEmpty == false { refused = true }
        text += delta
        if legacyFunctions, let function = choice.delta?.function_call {
            guard tools, !receivedTool,
                  let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let fields = choices.first?["delta"] as? [String: Any],
                  let legacy = fields["function_call"] as? [String: Any],
                  let params = legacy["arguments"] as? [String: Any] else { throw AssistantCloudStream.invalid }
            receivedTool = true
            toolName = function.name
            arguments = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        }
        for call in choice.delta?.tool_calls ?? [] {
            guard tools, call.index == 0, call.type == nil || call.type == "function" else { throw AssistantCloudStream.invalid }
            receivedTool = true
            toolName += call.function?.name ?? ""
            arguments += call.function?.arguments ?? ""
        }
        guard text.utf8.count <= 96_000, arguments.utf8.count <= 120_000, toolName.utf8.count <= 80 else {
            throw AssistantCloudStream.invalid
        }
        finishReason = choice.finish_reason
        return (delta.isEmpty ? nil : delta, nil)
    }

    private static func decodeChunk(_ data: Data, objectArguments: Bool) throws -> Chunk {
        let decoder = JSONDecoder()
        do { return try decoder.decode(Chunk.self, from: data) }
        catch {
            // Z.ai может прислать целый объект вместо фрагментов JSON-строки.
            guard objectArguments,
                  var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var choices = root["choices"] as? [[String: Any]], choices.count == 1,
                  var delta = choices[0]["delta"] as? [String: Any],
                  var calls = delta["tool_calls"] as? [[String: Any]] else { throw error }
            for index in calls.indices {
                guard var function = calls[index]["function"] as? [String: Any],
                      let args = function["arguments"] as? [String: Any] else { continue }
                function["arguments"] = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                calls[index]["function"] = function
            }
            delta["tool_calls"] = calls
            choices[0]["delta"] = delta
            root["choices"] = choices
            return try decoder.decode(Chunk.self, from: JSONSerialization.data(withJSONObject: root))
        }
    }

    private func complete() throws -> AssistantResponse {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if receivedTool {
            guard !refused, finishReason == (legacyFunctions ? "function_call" : "tool_calls"), toolName == "propose_changes" else { throw AssistantCloudStream.invalid }
            var result = try ActionPlanValidator.decode(arguments)
            guard (result.actions ?? []).allSatisfy({ $0.kind == .task && $0.linkTo == nil }) else {
                throw AssistantCloudStream.invalid
            }
            if !message.isEmpty { result.message = message }
            return result
        }
        guard finishReason == "stop", !message.isEmpty else { throw AssistantCloudStream.incomplete }
        return AssistantResponse(message: message)
    }

    private struct Chunk: Decodable {
        struct APIError: Decodable {}
        struct Usage: Decodable { let total_tokens: Int? }
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct Call: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int
                    let type: String?
                    let function: Function?
                }
                struct LegacyFunction: Decodable { let name: String }
                let function_call: LegacyFunction?
                let content: String?
                let refusal: String?
                let tool_calls: [Call]?
            }
            let index: Int
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let usage: Usage?
        let error: APIError?
    }
}
