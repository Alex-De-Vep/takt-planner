import Foundation
import EventKit

/// Снимок всех напоминаний. Особые действия сохраняем, даже если их нельзя редактировать в форме.
struct CalendarAlarm: Equatable, Identifiable {
    var id = UUID().uuidString
    var relativeOffset: TimeInterval = -900
    var absoluteDate: Date?
    var editable = true
    var actionTitle = "Уведомление"
    var originalDetails = ""

    static func legacy(_ offset: Int?) -> [Self] {
        offset.map { [Self(id: "legacy", relativeOffset: TimeInterval($0))] } ?? []
    }
    static func firstOffset(_ alarms: [Self]) -> Int? {
        alarms.first(where: { $0.absoluteDate == nil && $0.editable }).map { Int($0.relativeOffset) }
    }
}

@MainActor
enum EventKitAlarms {
    static func snapshot(_ alarms: [EKAlarm]) -> [CalendarAlarm] {
        alarms.enumerated().map { index, alarm in
            let location = alarm.structuredLocation
            let detail = [String(alarm.type.rawValue), alarm.emailAddress ?? "", alarm.soundName ?? "",
                          String(alarm.proximity.rawValue), location?.title ?? "",
                          location.map { String($0.radius) } ?? "",
                          location?.geoLocation.map { String($0.coordinate.latitude) + "," + String($0.coordinate.longitude) } ?? ""].joined(separator: "|")
            let action: String
            switch alarm.type {
            case .email: action = "Письмо"
            case .audio: action = "Звуковое напоминание"
            case .procedure: action = "Открытие файла"
            default: action = "Уведомление"
            }
            return CalendarAlarm(id: "alarm-\(index)", relativeOffset: alarm.relativeOffset, absoluteDate: alarm.absoluteDate,
                                 editable: alarm.type == .display && alarm.proximity == .none && location == nil,
                                 actionTitle: alarm.proximity == .none ? action : "Напоминание по местоположению",
                                 originalDetails: detail)
        }
    }

    static func updating(_ current: [EKAlarm], original: [CalendarAlarm], draft: [CalendarAlarm]) throws -> [EKAlarm] {
        guard original != draft else { return current }
        guard snapshot(current) == original else {
            throw CalendarFailure(message: "Напоминания события изменились. Откройте событие заново и повторите изменения.")
        }
        return try draft.map { alarm in
            if let index = original.firstIndex(where: { $0.id == alarm.id }), original[index] == alarm {
                return current[index].copy() as! EKAlarm
            }
            guard alarm.editable else { throw CalendarFailure(message: "Это напоминание можно изменить в системном календаре.") }
            return alarm.absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: alarm.relativeOffset)
        }
    }
}
