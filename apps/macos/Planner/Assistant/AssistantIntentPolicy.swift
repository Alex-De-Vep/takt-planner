import Foundation

/// Короткие ссылки уменьшают нагрузку на модель; настоящие ID остаются только у приложения.
struct AssistantReferences {
    let context: AssistantContext
    func folderToken(_ id: String?) -> String? {
        guard let id else { return nil }
        return context.folders.firstIndex { $0.id == id }.map { "f\($0)" } ?? id
    }
    func calendarToken(_ id: String?) -> String? {
        guard let id else { return nil }
        return context.calendars.firstIndex { $0.id == id }.map { "c\($0)" } ?? id
    }
    func folderID(_ token: String?) -> String? {
        guard let token else { return nil }
        return context.folders.enumerated().first { "f\($0.offset)" == token }?.element.id ?? token
    }
    func calendarID(_ token: String?) -> String? {
        guard let token else { return nil }
        return context.calendars.enumerated().first { "c\($0.offset)" == token }?.element.id ?? token
    }
    func outbound(_ original: AssistantProposal) -> AssistantProposal {
        var p = original
        p.folderID = folderToken(p.folderID); p.calendarID = calendarToken(p.calendarID)
        if p.linkTo == context.taskID, p.linkTo != nil { p.linkTo = "selected_task" }
        return p
    }
    func inbound(_ original: AssistantProposal) -> AssistantProposal {
        var p = original
        p.folderID = folderID(p.folderID); p.calendarID = calendarID(p.calendarID)
        if p.linkTo == "selected_task", let id = context.taskID { p.linkTo = id }
        return p
    }
}

/// Применяем только однозначные ограничения запроса; не угадываем сроки и неизвестные папки.
enum AssistantIntentPolicy {
    struct Destination {
        var specified = false
        var id: String?
        var name: String?
    }
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
    }
    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func groups(_ text: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    static func destination(in text: String, choices: [(id: String, name: String)], calendar: Bool, replyingToQuestion: Bool = false) -> Destination {
        let exact = choices.filter { folded($0.name) == folded(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if replyingToQuestion, exact.count == 1 { return Destination(specified: true, id: exact[0].id, name: exact[0].name) }
        let noun = calendar ? "(?:календар[ьеюя]|calendar)" : "(?:папк[а-я]*|folder)"
        let marker = "(?:(?:\\b(?:в|во|in|into|to)\\s+(?:the\\s+)?" + noun + "|(?:^|[,;])\\s*" + noun + ")\\s*:?[ ]*)(?:[«\"“]([^»\"”]+)[»\"”]|([^,.;\\n]+))"
        var found = groups(text, pattern: marker)
        if found.isEmpty, calendar {
            // Английское имя календаря может стоять перед словом calendar.
            found = groups(text, pattern: "(?:\\bin|\\bto)\\s+(?:the\\s+)?[«\"“]?(.+?)[»\"”]?\\s+calendar\\b").map { [$0[0], $0[1], ""] }
        }
        // Несколько назначений обрабатываются по отдельным фразам, а не одним общим выбором.
        guard found.count == 1, let match = found.first else { return Destination(specified: !found.isEmpty) }
        let quoted = !match[1].isEmpty
        let capture = (quoted ? match[1] : match[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = choices.sorted { $0.name.count > $1.name.count }
        let candidates = sorted.filter { choice in
            if quoted { return folded(capture) == folded(choice.name) }
            return folded(capture).range(of: "^" + NSRegularExpression.escapedPattern(for: folded(choice.name)) + "(?:$|\\s)", options: .regularExpression) != nil
        }
        if let longest = candidates.first {
            let equallyNamed = candidates.filter { folded($0.name) == folded(longest.name) }
            return Destination(specified: true, id: equallyNamed.count == 1 ? longest.id : nil, name: longest.name)
        }
        let end = capture.range(of: "\\s+(?:задач[а-я]*|без|со\\s+сроком|without|with|no\\s+due)\\b", options: [.regularExpression, .caseInsensitive])?.lowerBound ?? capture.endIndex
        return Destination(specified: true, name: String(capture[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func scope(_ text: String, title: String) -> String {
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: ";\n"))
        if pieces.count > 1, let piece = pieces.first(where: { folded($0).contains(folded(title)) }) { return piece }
        return text
    }
    private static func controlText(_ text: String, title: String) -> String {
        // Название «Без срока» или «Отметить на сегодня» — данные, а не команда редактору.
        let withoutTitle = text.replacingOccurrences(of: title, with: " ", options: .caseInsensitive)
        let labels = withoutTitle.replacingOccurrences(of: "(?i)(отметь|пометь|mark)\\s+[«\"“](на сегодня|today)[»\"”]", with: "$1 $2", options: .regularExpression)
        return labels.replacingOccurrences(of: "[«\"“][^»\"”]*[»\"”]", with: " ", options: .regularExpression)
    }
    static func noDeadline(_ text: String) -> Bool {
        let negative = "без\\s+срок[а-я]*|срок\\s+(?:не\\s+нужен|не\\s+указыв[а-я]*)|\\bno\\s+(?:due\\s+date|deadline)\\b|without\\s+(?:a\\s+)?(?:deadline|due\\s+date)"
        guard let re = try? NSRegularExpression(pattern: negative, options: .caseInsensitive),
              let last = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return false }
        let positive = "(?:срок[а-я]*|дедлайн|due|deadline)\\s*(?:на|:|on)?\\s*(?:сегодня|завтра|[0-9]|tomorrow|today)"
        if let later = try? NSRegularExpression(pattern: positive, options: .caseInsensitive),
           later.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains(where: { $0.range.location > last.range.location }) { return false }
        return true
    }
    static func today(_ text: String) -> Bool? {
        if matches(text, "(?:убери|сними|не\\s+отмечай|не\\s+ставь).{0,40}(?:сегодня|звезд|звёзд)|(?:unstar|unmark|(?:do\\s+not|don't)\\s+(?:mark|star)).{0,30}today") { return false }
        if matches(text, "(?:отметь|пометь|отметить|поставь).{0,45}(?:сегодня|звезд|звёзд)|\\b(?:mark|star|focus)\\b.{0,35}(?:today|star)") { return true }
        return nil
    }
    static func correction(_ text: String) -> Bool {
        matches(text, "исправ|переимен|измени|перенеси|поменяй|\\b(?:rename|change|correct|update|move)\\b")
    }
    private static func changesDate(_ text: String) -> Bool {
        matches(text, "сегодня|завтра|послезавтра|понедельник|вторник|сред[ау]|четверг|пятниц|суббот|воскресень|через\\s+\\d+\\s+д|\\d{4}-\\d{2}-\\d{2}|\\d{1,2}[./]\\d{1,2}|\\d{1,2}\\s+(?:январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|октябр|ноябр|декабр)|\\b(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b")
    }
    static func normalize(_ response: AssistantResponse, thread: AssistantThread, context: AssistantContext) -> AssistantResponse {
        let references = AssistantReferences(context: context)
        var result = response
        var actions = (response.actions ?? []).map(references.inbound)
        let latest = thread.messages.last(where: { $0.role == .user })?.text ?? ""
        let previousQuestions = thread.messages.dropLast().last(where: { $0.role == .assistant })?.questions ?? []
        let markPending = today(latest) != nil && !matches(latest, "созда[а-я]*|добав[а-я]*|\\bcreate\\b|\\badd\\b")
        let followup = !previousQuestions.isEmpty || correction(latest) || markPending
        let pending = thread.actions.filter { [.pending, .failed].contains($0.status) && $0.createdEventID == nil }
        var remapped: [String: String] = [:]
        if followup {
            for kind in [AssistantProposal.Kind.task, .event] {
                let old = pending.filter { $0.proposal.kind == kind }
                let indexes = actions.indices.filter { actions[$0].kind == kind }
                if old.count == 1, indexes.count == 1, let index = indexes.first {
                    remapped[actions[index].key] = old[0].proposal.key
                    actions[index].key = old[0].proposal.key
                    if kind == .event, !changesDate(latest) { actions[index].date = old[0].proposal.date }
                    if actions[index].linkTo == nil { actions[index].linkTo = old[0].proposal.linkTo }
                }
            }
            for index in actions.indices { if let key = actions[index].linkTo { actions[index].linkTo = remapped[key] ?? key } }
        }
        let folderChoices = context.folders.map { (id: $0.id, name: $0.name) }
        let calendarChoices = context.calendars.map { (id: $0.id, name: $0.name) }
        var folderQuestion: Destination?, calendarQuestion: Destination?
        var timeQuestion: AssistantProposal?
        let folderReply = previousQuestions.contains { matches($0.text, "папк|folder") }
        let calendarReply = previousQuestions.contains { matches($0.text, "календар|calendar") }
        for index in actions.indices {
            var p = actions[index]
            let sameKindCount = actions.filter { $0.kind == p.kind }.count
            let text = sameKindCount > 1 ? scope(latest, title: p.title) : latest
            let specificControls = sameKindCount == 1 || text != latest
            let controls = controlText(text, title: p.title)
            let destinationText = text.replacingOccurrences(of: "«" + p.title + "»", with: " ")
                .replacingOccurrences(of: "\"" + p.title + "\"", with: " ")
            let old = followup ? pending.first { $0.proposal.key == p.key }?.proposal : nil
            if p.kind == .task {
                let useDefault = matches(controls, "папк[а-я]*\\s+по\\s+умолчанию|\\bdefault\\s+folder\\b")
                let destination = destination(in: destinationText, choices: folderChoices, calendar: false, replyingToQuestion: folderReply)
                if useDefault { p.folderID = context.defaultFolderID }
                else if destination.specified {
                    if destination.id != nil || destination.name != nil { p.folderID = destination.id }
                    if destination.id == nil, destination.name != nil { folderQuestion = destination }
                } else if let old { p.folderID = old.folderID }
                else {
                    // Не подменяем явное «во Входящие» или «в Личное» текущей папкой.
                    let named = folderChoices.filter { choice in
                        matches(destinationText, "(?:\\bв|\\bво|\\bin|\\binto|\\bto)\\s+(?:the\\s+)?" + "[«\"“]?" + NSRegularExpression.escapedPattern(for: choice.name) + "[»\"”]?(?:$|[\\s,.;])")
                    }
                    p.folderID = named.count == 1 ? named[0].id : (named.isEmpty ? context.defaultFolderID : p.folderID)
                }
                let deadlineMentioned = matches(controls, "срок|дедлайн|\\bdue\\b|\\bdeadline\\b")
                let dateControls = today(controls) != nil && !deadlineMentioned
                    ? controls.replacingOccurrences(of: "сегодня|today", with: "", options: [.regularExpression, .caseInsensitive]) : controls
                if let old, !changesDate(dateControls), !deadlineMentioned { p.date = old.date; p.time = old.time }
                if specificControls, noDeadline(controls) { p.date = nil; p.time = nil }
                if (text.contains("«" + p.title + "»") || text.contains("\"" + p.title + "\"")), today(p.title) != nil, today(controls) == nil { p.today = nil }
                if specificControls, let focus = today(controls) {
                    p.today = focus
                    if old == nil, !matches(controls, "срок|дедлайн|\\bdue\\b|\\bdeadline\\b|\\bby\\b"), !changesDate(controls.replacingOccurrences(of: "сегодня", with: "")) { p.date = nil; p.time = nil }
                    if !matches(controls, "подзадач|пункт|чек.?лист|checklist|subtask|\\bsteps?\\b") {
                        p.checklist = p.checklist?.filter { today($0) == nil }
                    }
                }
            } else {
                let destination = destination(in: destinationText, choices: calendarChoices, calendar: true, replyingToQuestion: calendarReply)
                if destination.specified {
                    if destination.id != nil || destination.name != nil { p.calendarID = destination.id }
                    if destination.id == nil, destination.name != nil { calendarQuestion = destination }
                } else if let old { p.calendarID = old.calendarID }
                else { p.calendarID = context.defaultCalendarID }
                let time = AssistantEventTimePolicy.resolve(p, text: controls, old: old, context: context)
                p = time.proposal
                if time.needsTime { timeQuestion = p }
                // Связь не появляется по догадке модели. Явное планирование свяжет событие ниже.
                if matches(controls, "без\\s+напомин|не\\s+напомин|no\\s+(?:reminder|alert)|without\\s+(?:a\\s+)?reminder") { p.reminderMinutes = nil }
                else if !matches(controls, "напом|уведомл|remind|alert|notification") {
                    if let old { p.reminderMinutes = old.reminderMinutes }
                    else { p.reminderMinutes = context.reminderMinutes }
                }
                p.linkTo = old?.linkTo
                if matches(controls, "самостоятельн|отдельн[а-я]*\\s+событ|не\\s+связывай|standalone|independent|unlinked") { p.linkTo = nil }
            }
            actions[index] = p
        }
        let events = actions.indices.filter { actions[$0].kind == .event }
        let tasks = actions.indices.filter { actions[$0].kind == .task }
        let linkText = latest.replacingOccurrences(of: "[«\"“][^»\"”]*[»\"”]", with: " ", options: .regularExpression)
        let independent = matches(linkText, "самостоятельн|отдельн[а-я]*\\s+событ|не\\s+связывай|standalone|independent|unlinked")
        let planning = matches(linkText, "выдел[а-я]*|запланир|заброни|\\b(?:schedule|reserve|block|allocate|plan)\\b")
        if events.count == 1, let eventIndex = events.first, planning, !independent {
            if let taskID = context.taskID, (matches(linkText, "открыт[а-я]*\\s+задач|выбран[а-я]*\\s+задач|для\\s+этой\\s+задач|(?:selected|current|open)\\s+task|for\\s+this\\s+task") || context.taskTitle.map { folded(latest).contains(folded($0)) } == true), tasks.isEmpty {
                actions[eventIndex].linkTo = taskID
            } else if tasks.count == 1, let taskIndex = tasks.first,
                      matches(latest, "для\\s+(?:этой\\s+)?новой\\s+задач|для\\s+этой\\s+задач|для\\s+не[её]|for\\s+(?:this|the\\s+new)\\s+task") {
                actions[eventIndex].linkTo = actions[taskIndex].key
            }
        }
        result.actions = actions
        let english = context.language == "en"
        if let destination = folderQuestion {
            let name = destination.name ?? ""
            result.questions = [AssistantQuestion(text: english ? "Folder ‘\(name)’ was not found or is ambiguous. Which folder should I use?" : "Папка «\(name)» не найдена или неоднозначна. В какую папку добавить задачу?", options: context.folders.map(\.name))]
        } else if let destination = calendarQuestion {
            let name = destination.name ?? ""
            result.questions = [AssistantQuestion(text: english ? "Calendar ‘\(name)’ was not found or is ambiguous. Which calendar should I use?" : "Календарь «\(name)» не найден или неоднозначен. Какой календарь использовать?", options: context.calendars.map(\.name))]
        } else if let event = timeQuestion {
            let options = english ? ["09:00", "12:00", "15:00", "All day"] : ["09:00", "12:00", "15:00", "Весь день"]
            result.questions = [AssistantQuestion(text: english ? "When should I schedule ‘\(event.title)’? Please specify the time or choose all day." : "Во сколько запланировать «\(event.title)»? Укажите время или выберите весь день.", options: options)]
        }
        return result
    }
}
