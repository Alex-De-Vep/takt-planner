import CoreFoundation
import Foundation

/// Метаданные берём из ответа API отдельно от аргументов, предложенных моделью.
struct AssistantCloudCompletion: Sendable {
    let response: AssistantResponse
    let usage: AssistantCloudUsage
}

/// Карточки появляются только после response.completed. Прерванный поток может содержать готовые на вид аргументы.
struct AssistantCloudStream {
    static let invalid = AssistantFailure(message: "Не удалось проверить облачный ответ. Повторите запрос.")
    static let incomplete = AssistantFailure(message: "Облачный ответ прервался. Повторите запрос.")
    private var lines: [String] = []
    private var eventSize = 0
    private var previewSize = 0
    private let supportsTools: Bool

    init(supportsTools: Bool = true) { self.supportsTools = supportsTools }

    mutating func consume(_ line: String) throws -> (delta: String?, reply: AssistantCloudCompletion?) {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            eventSize += value.utf8.count
            guard eventSize <= 512_000 else { throw Self.invalid }
            lines.append(value.first == " " ? String(value.dropFirst()) : String(value))
            return (nil, nil)
        }
        guard line.isEmpty, !lines.isEmpty else { return (nil, nil) }
        let payload = lines.joined(separator: "\n")
        lines.removeAll(keepingCapacity: true)
        eventSize = 0
        guard payload != "[DONE]" else { throw Self.incomplete }
        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let type = event["type"] as? String else { throw Self.invalid }
        switch type {
        case "response.output_text.delta":
            let delta = event["delta"] as? String ?? ""
            previewSize += delta.utf8.count
            guard previewSize <= 96_000 else { throw Self.invalid }
            return (delta, nil)
        case "response.completed":
            guard let response = event["response"] as? [String: Any],
                  let output = response["output"] as? [[String: Any]],
                  response["status"] as? String == "completed" else { throw Self.incomplete }
            let total = (response["usage"] as? [String: Any])?["total_tokens"] as? NSNumber
            let tokens = total.flatMap { value -> Int? in
                guard CFGetTypeID(value) != CFBooleanGetTypeID(),
                      let count = value as? Int, count >= 0, Int32(exactly: count) != nil else { return nil }
                return count
            }
            return (nil, try AssistantCloudCompletion(response: Self.decode(output, supportsTools: supportsTools), usage: .init(tokens: tokens)))
        case "response.incomplete", "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? event
            if let code = error["code"] as? String {
                let parameter = error["param"] as? String
                switch code {
                case "subscription_sharing_usage_limit_exceeded", "rate_limit_exceeded":
                    throw ChatGPTHTTPError(status: 429, code: code, parameter: parameter)
                case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
                    throw ChatGPTHTTPError(status: 503, code: code, parameter: parameter)
                case "subscription_sharing_user_not_eligible":
                    throw ChatGPTHTTPError(status: 403, code: code, parameter: parameter)
                case "subscription_sharing_unsupported_capability":
                    throw ChatGPTHTTPError(status: 400, code: code, parameter: parameter)
                default: break
                }
            }
            throw Self.incomplete
        default:
            return (nil, nil)
        }
    }

    private static func decode(_ output: [[String: Any]], supportsTools: Bool) throws -> AssistantResponse {
        var text: [String] = []
        var proposal: AssistantResponse?
        for item in output {
            switch item["type"] as? String {
            case "message":
                guard let content = item["content"] as? [[String: Any]] else { throw invalid }
                for part in content {
                    if part["type"] as? String == "output_text", let value = part["text"] as? String { text.append(value) }
                    if part["type"] as? String == "refusal", let value = part["refusal"] as? String { text.append(value) }
                }
            case "function_call":
                let name = item["name"] as? String
                guard supportsTools, proposal == nil, name == "propose_changes" || name == "planner.propose_changes",
                      item["namespace"] == nil || item["namespace"] as? String == "planner",
                      let arguments = item["arguments"] as? String, arguments.utf8.count <= 120_000 else { throw invalid }
                let value = try ActionPlanValidator.decode(arguments)
                guard (value.actions ?? []).allSatisfy({ $0.kind == .task }) else { throw invalid }
                proposal = value
            default: break
            }
        }
        let message = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = proposal ?? AssistantResponse(message: message)
        if !message.isEmpty { result.message = message }
        guard !result.message.isEmpty || result.actions?.isEmpty == false || result.textEdit != nil || result.questions?.isEmpty == false else {
            throw invalid
        }
        return result
    }
}
