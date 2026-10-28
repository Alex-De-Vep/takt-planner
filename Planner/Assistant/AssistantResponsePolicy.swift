import Foundation

/// Значения по умолчанию принадлежат приложению: модель не может сама включить напоминание.
enum AssistantResponsePolicy {
    static func normalize(_ response: AssistantResponse, thread: AssistantThread, context: AssistantContext) -> AssistantResponse {
        var response = response
        let requestedReminder = thread.messages.contains { message in
            message.role == .user && message.text.range(of: "напом|уведомл|remind|alert|notification", options: [.regularExpression, .caseInsensitive]) != nil
        }
        if !requestedReminder {
            response.actions = response.actions?.map { p in
                var p = p
                if p.kind == .event { p.reminderMinutes = context.reminderMinutes }
                return p
            }
        }
        // Статус предложения сообщает приложение, чтобы модель не заявляла о несохранённом результате.
        let english = context.language == "en" || (context.language == "system" && Locale.current.language.languageCode?.identifier == "en")
        if response.questions?.isEmpty == false {
            response.message = english ? "Please clarify the details." : "Уточните детали предложения."
        } else if response.actions?.isEmpty == false {
            response.message = english ? "Review the proposals before creating them." : "Проверьте предложения перед созданием."
        }
        return response
    }
}
