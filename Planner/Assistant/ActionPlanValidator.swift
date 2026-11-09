import Foundation

/// Строгий разбор не переносит несуществующее время через DST молча.
enum ActionPlanValidator {
    static func date(_ day: String?, time: String?, zone: String) throws -> Date {
        guard let day, let timeZone = TimeZone(identifier: zone) else { throw AssistantFailure(message: "Укажите дату.") }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = timeZone
        format.dateFormat = time == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        format.isLenient = false
        let input = day + (time.map { " " + $0 } ?? "")
        guard let result = format.date(from: input), format.string(from: result) == input else {
            throw AssistantFailure(message: "Проверьте дату и время.")
        }
        return result
    }
    static func folder(_ id: String) -> TaskFilter? {
        switch id {
        case "inbox": .inbox
        case "week": .week
        case "month": .month
        default: UUID(uuidString: id).map(TaskFilter.folder)
        }
    }
    static func problems(_ action: AssistantAction, folders: [AssistantFolder], calendars: [AssistantCalendar]) -> [String] {
        let p = action.proposal
        var errors: [String] = []
        if p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Введите название.") }
        if p.title.count > 500 || (p.description?.count ?? 0) > 20000 || (p.checklist?.count ?? 0) > 100 {
            errors.append("Предложение слишком большое. Разделите его на несколько запросов.")
        }
        if p.kind == .task {
            if p.reminderMinutes != nil { errors.append("Для задач доступны уведомления о сроке из общих настроек.") }
            if !folders.contains(where: { $0.id == (p.folderID ?? "") }) { errors.append("Выберите существующую папку.") }
            if p.date != nil, (try? date(p.date, time: p.time, zone: action.context.timeZoneID)) == nil { errors.append("Проверьте срок задачи.") }
            if p.date == nil && p.time != nil { errors.append("Укажите дату.") }
        } else {
            if action.createdEventID == nil && !calendars.contains(where: { $0.id == p.calendarID }) { errors.append("Выберите доступный календарь для записи.") }
            do { _ = try eventDraft(action) } catch { errors.append(error.localizedDescription) }
        }
        return errors
    }
    static func eventDraft(_ action: AssistantAction) throws -> EventDraft {
        let p = action.proposal
        guard p.allDay == true || p.time != nil else { throw AssistantFailure(message: "Во сколько запланировать событие?") }
        let start = try date(p.date, time: p.allDay == true ? nil : p.time, zone: action.context.timeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: action.context.timeZoneID) ?? .current
        var draft = EventDraft(day: start, calendarID: p.calendarID ?? "", title: p.title)
        draft.start = start; draft.allDay = p.allDay ?? false; draft.timeZoneID = action.context.timeZoneID
        if draft.allDay { draft.end = try date(p.endDate ?? p.date, time: nil, zone: action.context.timeZoneID) }
        else if let endTime = p.endTime { draft.end = try date(p.endDate ?? p.date, time: endTime, zone: action.context.timeZoneID) }
        else {
            let duration = p.durationMinutes ?? action.context.durationMinutes
            guard (1...10080).contains(duration) else { throw AssistantFailure(message: "Проверьте длительность события.") }
            draft.end = calendar.date(byAdding: .minute, value: duration, to: start)!
        }
        draft.notes = p.description ?? ""
        if let reminder = p.reminderMinutes {
            guard (0...40320).contains(reminder) else { throw AssistantFailure(message: "Проверьте напоминание.") }
            draft.reminder = -reminder * 60
        }
        _ = try draft.interval(calendar: calendar)
        return draft
    }
    static func decode(_ output: String) throws -> AssistantResponse {
        // Обрезанный ответ никогда не становится исполняемым действием.
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let range = text.range(of: "</think>") { text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if text.hasPrefix("```json"), text.hasSuffix("```") { text = String(text.dropFirst(7).dropLast(3)) }
        // Разрешаем только внешнюю markdown-обёртку. Сам JSON не достраиваем и не исправляем.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespacesAndNewlines))
        var payload: Any
        do { payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
        catch { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Ответ не является полным JSON.", underlyingError: error)) }
        // Некоторые модели возвращают пункты как {text: ...}. Принимаем только однозначную
        // обёртку одного текста; флаги выполнения и прочие поля не отбрасываем молча.
        if var root = payload as? [String: Any], var actions = root["actions"] as? [[String: Any]] {
            for index in actions.indices {
                guard let items = actions[index]["checklist"] as? [[String: Any]], !items.isEmpty else { continue }
                let strings = items.compactMap { item -> String? in
                    guard item.count == 1 else { return nil }
                    return (item["text"] as? String) ?? (item["title"] as? String)
                }
                if strings.count == items.count { actions[index]["checklist"] = strings }
            }
            root["actions"] = actions; payload = root
        }
        // Текстовый редактор передаёт пункты одной строкой: маленькой модели не нужен вложенный массив.
        // Это только нормализация полного валидного JSON; оборванный ответ не достраивается.
        if var root = payload as? [String: Any], var edit = root["textEdit"] as? [String: Any],
           let lines = edit["checklistText"] as? String, edit["checklist"] == nil {
            edit["checklist"] = lines.components(separatedBy: .newlines).map {
                $0.replacingOccurrences(of: #"^\s*(?:[-*•]\s+|[0-9]+[.)]\s+)"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            edit["checklistText"] = nil
            root["textEdit"] = edit; payload = root
        }
        let canonical = try JSONSerialization.data(withJSONObject: payload)
        let response = try JSONDecoder().decode(AssistantResponse.self, from: canonical)
        guard (response.actions?.count ?? 0) <= 20, (response.questions?.count ?? 0) <= 5,
              Set((response.actions ?? []).map(\.key)).count == (response.actions?.count ?? 0) else {
            throw AssistantFailure(message: "Не удалось проверить ответ модели. Упростите запрос и повторите.")
        }
        return response
    }
}
