import Foundation

/// Значения по умолчанию принадлежат приложению: модель не может сама включить напоминание.
enum AssistantResponsePolicy {
    static func normalize(_ response: AssistantResponse, thread: AssistantThread, context: AssistantContext) -> AssistantResponse {
        var response = AssistantIntentPolicy.normalize(response, thread: thread, context: context)
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
