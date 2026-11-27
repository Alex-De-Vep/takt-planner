import Foundation

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
    static func referencesOpenTask(_ text: String) -> Bool {
        matches(text, #"(?:эт[уаой]{1,2}|открыт[а-я]*|выбран[а-я]*)\s+задач|(?:this|current|open|selected)\s+task"#)
    }

    // Номер из карточки сохраняет цель и для реплик без изменений.
    static func referencedDraftNumber(_ text: String) -> Int? {
        let references = groups(text, pattern: #"(?<!\w)(?:[#№]\s*|(?:задач[а-я]*|черновик[а-я]*|task|draft)\s+(?:номер\s+|number\s+)?)([1-9][0-9]*)(?!\w)"#)
        if references.count == 1, let number = Int(references[0][1]) { return number }
        let words = [#"перв[а-я]+|first"#, #"втор[а-я]+|second"#, #"треть[а-я]+|third"#,
                     #"четв[её]рт[а-я]+|fourth"#, #"пят[а-я]+|fifth"#]
        let ordinals = words.indices.filter {
            matches(text, #"\b(?:"# + words[$0] + #")\s+(?:задач[а-я]+|черновик[а-я]*|task|draft)\b"#)
        }
        return ordinals.count == 1 ? ordinals[0] + 1 : nil
    }

    static func savedTaskQuery(_ text: String) -> String? {
        let quoted = #"(?:задач[ауиеё]|task)\s+[«"“]([^»"”]+)[»"”]"#
        let edit = #"^\s*(?:найди|открой|улучши|сократи|уточни|доработай|переформулируй|перепиши|распиши|разбей|переименуй|измени|обнови|find|open|improve|shorten|refine|rewrite|expand|split|rename|edit|update)\b"#
        guard matches(text, edit) else { return nil }
        let named = #"^\s*(?:найди\s+задачу\s+(?:про\s+|с\s+названием\s+)?|find\s+(?:the\s+)?task\s+(?:about\s+|called\s+)?)(.+?)(?:\s+и\s+(?:сократи|улучши|уточни|доработай|переформулируй|перепиши|распиши|разбей|переименуй|измени|обнови)\b|\s+and\s+(?:shorten|improve|refine|rewrite|expand|split|rename|edit|update)\b|[.!?]*$)"#
        return (groups(text, pattern: quoted).first ?? groups(text, pattern: named).first)?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func destination(in text: String, choices: [(id: String, name: String)], replyingToQuestion: Bool = false) -> Destination {
        let exact = choices.filter { folded($0.name) == folded(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if replyingToQuestion, exact.count == 1 { return Destination(specified: true, id: exact[0].id, name: exact[0].name) }
        let noun = "(?:папк[а-я]*|folder)"
        let marker = "(?:(?:\\b(?:в|во|in|into|to)\\s+(?:the\\s+)?" + noun + "|(?:^|[,;])\\s*" + noun + ")\\s*:?[ ]*)(?:[«\"“]([^»\"”]+)[»\"”]|([^,.;\\n]+))"
        let found = groups(text, pattern: marker)
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
    static func noDeadline(_ text: String) -> Bool {
        let negative = "без\\s+срок[а-я]*|срок\\s+(?:не\\s+нужен|не\\s+указыв[а-я]*)|\\bno\\s+(?:due\\s+date|deadline)\\b|without\\s+(?:a\\s+)?(?:deadline|due\\s+date)"
        guard let re = try? NSRegularExpression(pattern: negative, options: .caseInsensitive),
              let last = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return false }
        let positive = "(?:срок[а-я]*|дедлайн|due|deadline)\\s*(?:на|:|on)?\\s*(?:сегодня|завтра|[0-9]|tomorrow|today)"
        if let later = try? NSRegularExpression(pattern: positive, options: .caseInsensitive),
           later.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains(where: { $0.range.location > last.range.location }) { return false }
        return true
    }
}
