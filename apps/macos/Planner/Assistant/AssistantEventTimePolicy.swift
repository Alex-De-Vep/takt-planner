import Foundation

/// Событие не получает время по умолчанию: отсутствие точного времени требует уточнения.
enum AssistantEventTimePolicy {
    struct Resolution { var proposal: AssistantProposal; var needsTime: Bool }
    private static func captures(_ text: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    static func clocks(_ text: String) -> [String] {
        let ns = text as NSString
        var found: [(Int, String)] = []
        func collect(_ pattern: String, format: (NSTextCheckingResult) -> String?) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let value = format(match) { found.append((match.range.location, value)) }
            }
        }
        collect("(?<![0-9])([01]?[0-9]|2[0-3]):([0-5][0-9])(?![0-9])") { match in
            let prefix = ns.substring(to: match.range.location)
            guard !AssistantIntentPolicy.matches(prefix, "(?:\\bна|\\bfor)\\s*$") else { return nil }
            return String(format: "%02d:%02d", Int(ns.substring(with: match.range(at: 1)))!, Int(ns.substring(with: match.range(at: 2)))!)
        }
        collect("(?:\\bв|\\bat|\\bс|\\bfrom)\\s+([01]?[0-9]|2[0-3])(?:\\s*(утра|дня|вечера|ночи|am|pm|час[а-я]*|hours?))?(?=$|[\\s,.;])") { match in
            let suffix = ns.substring(from: NSMaxRange(match.range))
            guard !AssistantIntentPolicy.matches(suffix, "^\\s+(?:январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|октябр|ноябр|декабр)") else { return nil }
            var hour = Int(ns.substring(with: match.range(at: 1)))!
            let period = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2)).lowercased()
            if ["вечера", "дня", "pm"].contains(period), hour < 12 { hour += 12 }
            if ["ночи", "am"].contains(period), hour == 12 { hour = 0 }
            return String(format: "%02d:00", hour)
        }
        collect("\\bполноч[ььи]\\b|\\bmidnight\\b") { _ in "00:00" }
        collect("\\bполдень\\b|\\bnoon\\b") { _ in "12:00" }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
    static func duration(_ text: String) -> Int? {
        if AssistantIntentPolicy.matches(text, "(?:на|for)\\s+(?:полтора\\s+часа|an?\\s+hour\\s+and\\s+a\\s+half)") { return 90 }
        if AssistantIntentPolicy.matches(text, "(?:на|for)\\s+(?:полчаса|half\\s+an?\\s+hour)") { return 30 }
        if AssistantIntentPolicy.matches(text, "(?:на|for)\\s+(?:час|an?\\s+hour)\\b") { return 60 }
        let words = ["одну": 1, "один": 1, "две": 2, "два": 2, "три": 3, "четыре": 4, "пять": 5, "десять": 10,
                     "пятнадцать": 15, "двадцать": 20, "тридцать": 30, "сорок": 40, "сорок пять": 45, "шестьдесят": 60, "девяносто": 90, "двадцать пять": 25,
                     "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15,
                     "twenty": 20, "twenty-five": 25, "thirty": 30, "forty": 40, "forty-five": 45, "sixty": 60, "ninety": 90]
        let options = words.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let values = captures(text, "(?:\\bна|\\bfor|длительност[а-я]*|duration(?:\\s+of)?|займ[её]т)\\s*:?\\s+([0-9]+|" + options + ")\\s*[- ]?(мин[а-я]*|minutes?|mins?|час[а-я]*|hours?)\\b")
        if let value = values.first, let number = Int(value[0]) ?? words[value[0].lowercased()] {
            let product = number.multipliedReportingOverflow(by: AssistantIntentPolicy.matches(value[1], "час|hour") ? 60 : 1)
            return product.overflow ? 10081 : product.partialValue
        }
        if let value = captures(text, "\\b([0-9]+)-minute\\b").first { return Int(value[0]) ?? 10081 }
        let fallback = "([0-9]+|" + options + ")\\s+(мин[а-я]*|minutes?|mins?|час[а-я]*|hours?)\\b"
        if let re = try? NSRegularExpression(pattern: fallback, options: .caseInsensitive) {
            let ns = text as NSString
            let candidates = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { match in
                let prefix = ns.substring(to: match.range.location)
                return !AssistantIntentPolicy.matches(prefix, "(?:\\bза|\\bчерез|\\bin)\\s*$|(?:напом[а-я]*|remind).{0,25}$")
            }
            if candidates.count == 1, let match = candidates.first {
                let number = Int(ns.substring(with: match.range(at: 1))) ?? words[ns.substring(with: match.range(at: 1)).lowercased()] ?? 10081
                let factor = AssistantIntentPolicy.matches(ns.substring(with: match.range(at: 2)), "час|hour") ? 60 : 1
                let product = number.multipliedReportingOverflow(by: factor)
                return product.overflow ? 10081 : product.partialValue
            }
        }
        if let value = captures(text, "(?:\\bна|\\bfor)\\s+([0-9]{1,3}):([0-5][0-9])").first { return Int(value[0])! * 60 + Int(value[1])! }
        return nil
    }
    static func resolve(_ original: AssistantProposal, text: String, old: AssistantProposal?, context: AssistantContext) -> Resolution {
        var p = original
        let allDay = AssistantIntentPolicy.matches(text, "весь\\s+день|целый\\s+день|all[ -]day|whole\\s+day")
        let times = clocks(text)
        if allDay {
            p.allDay = true; p.time = nil; p.endTime = nil
            return Resolution(proposal: p, needsTime: false)
        }
        if let first = times.first {
            let interval = times.count == 2 && AssistantIntentPolicy.matches(text, "(?:\\bс|\\bfrom).{0,35}(?:\\bдо|\\bto|\\buntil)")
            let time: String
            if times.count > 1, !interval {
                guard let proposed = p.time, times.contains(proposed) else { p.time = nil; p.allDay = false; return Resolution(proposal: p, needsTime: true) }
                time = proposed
            } else { time = first }
            p.time = time; p.allDay = false
            if interval, let start = try? ActionPlanValidator.date(p.date, time: time, zone: context.timeZoneID) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: context.timeZoneID) ?? .current
                let formatter = DateFormatter(); formatter.calendar = cal; formatter.timeZone = cal.timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                let datePattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}[./][0-9]{1,2}|[0-9]{1,2}\\s+(?:январ|феврал|март|апрел|ма[йя]|июн|июл|август|сентябр|октябр|ноябр|декабр)"
                let dateCount = (try? NSRegularExpression(pattern: datePattern, options: .caseInsensitive))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
                let endDay = dateCount >= 2 && p.endDate != nil ? p.endDate
                    : (times[1] <= time ? formatter.string(from: cal.date(byAdding: .day, value: 1, to: start)!) : p.date)
                if let end = try? ActionPlanValidator.date(endDay, time: times[1], zone: context.timeZoneID) {
                    p.durationMinutes = Int(end.timeIntervalSince(start) / 60)
                }
            } else {
                let previous = old.flatMap { value -> Int? in
                    guard value.allDay != true, let draft = try? ActionPlanValidator.eventDraft(.init(proposal: value, context: context)) else { return nil }
                    return Int(draft.end.timeIntervalSince(draft.start) / 60)
                }
                p.durationMinutes = duration(text) ?? previous ?? context.durationMinutes
            }
            p.endDate = nil; p.endTime = nil
            return Resolution(proposal: p, needsTime: false)
        }
        if let old {
            p.time = old.time; p.allDay = old.allDay
            if old.allDay != true {
                let previous = (try? ActionPlanValidator.eventDraft(.init(proposal: old, context: context))).map { Int($0.end.timeIntervalSince($0.start) / 60) }
                p.durationMinutes = duration(text) ?? previous ?? context.durationMinutes
                p.endDate = nil; p.endTime = nil
            }
            return Resolution(proposal: p, needsTime: old.allDay != true && old.time == nil)
        }
        // Нет свидетельства точного времени. Даже корректный JSON с 00:00 не даёт права его придумать.
        p.time = nil; p.allDay = false; p.endTime = nil
        return Resolution(proposal: p, needsTime: true)
    }
}
