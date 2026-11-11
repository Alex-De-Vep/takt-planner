import SwiftUI

struct CalendarAlarmsEditor: View {
    @Environment(\.translations) private var strings
    @Binding var alarms: [CalendarAlarm]
    let eventStart: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings["Напоминания"]).font(.headline)
            if alarms.isEmpty { Text(strings["Нет"]).foregroundStyle(.secondary) }
            ForEach($alarms) { $alarm in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if alarm.editable {
                            Picker(strings["Тип напоминания"], selection: Binding(get: { alarm.absoluteDate != nil }, set: {
                                alarm.absoluteDate = $0 ? eventStart.addingTimeInterval(-900) : nil
                            })) {
                                Text(strings["До начала события"]).tag(false)
                                Text(strings["В указанное время"]).tag(true)
                            }.labelsHidden().accessibilityIdentifier("calendar-alarm-kind-" + alarm.id)
                            if alarm.absoluteDate != nil {
                                DatePicker(strings["Дата и время напоминания"], selection: Binding(
                                    get: { alarm.absoluteDate ?? eventStart }, set: { alarm.absoluteDate = $0 }),
                                    displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden().accessibilityIdentifier("calendar-alarm-date-" + alarm.id)
                            } else {
                                Picker(strings["Напоминание"], selection: $alarm.relativeOffset) {
                                    Text(strings["В момент начала"]).tag(0.0)
                                    Text(strings["За 5 минут"]).tag(-300.0)
                                    Text(strings["За 15 минут"]).tag(-900.0)
                                    Text(strings["За 30 минут"]).tag(-1800.0)
                                    Text(strings["За час"]).tag(-3600.0)
                                    Text(strings["За день"]).tag(-86400.0)
                                    if ![0.0, -300, -900, -1800, -3600, -86400].contains(alarm.relativeOffset) {
                                        Text(strings.format("%d мин. от начала", Int(alarm.relativeOffset / 60))).tag(alarm.relativeOffset)
                                    }
                                }.labelsHidden().accessibilityIdentifier("calendar-alarm-offset-" + alarm.id)
                            }
                        } else {
                            Text(strings[alarm.actionTitle])
                            if let date = alarm.absoluteDate { Text(date, format: .dateTime.day().month().year().hour().minute()) }
                            else { Text(strings.format("%d мин. от начала", Int(alarm.relativeOffset / 60))) }
                            Text(strings["Это напоминание можно изменить в системном календаре."])
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button { alarms.removeAll { $0.id == alarm.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help(strings["Удалить напоминание"])
                        .accessibilityLabel(strings["Удалить напоминание"])
                        .accessibilityIdentifier("remove-calendar-alarm-" + alarm.id)
                }
            }
            if alarms.contains(where: { $0.absoluteDate != nil }) {
                Text(strings["Напоминание на конкретную дату не меняется при переносе события."])
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(strings["Добавить напоминание"]) { alarms.append(CalendarAlarm()) }
                    .accessibilityIdentifier("add-calendar-alarm")
                if !alarms.isEmpty {
                    Button(strings["Убрать все напоминания"]) { alarms = [] }
                        .accessibilityIdentifier("clear-calendar-alarms")
                }
            }
        }.padding(.vertical, 4)
    }
}

struct CalendarAlarmsSummary: View {
    @Environment(\.translations) private var strings
    let alarms: [CalendarAlarm]
    var body: some View {
        if !alarms.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings["Напоминания"]).font(.headline)
                ForEach(alarms) { alarm in
                    if let date = alarm.absoluteDate {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text(strings[alarm.actionTitle] + " · " + strings.format("%d мин. от начала", Int(alarm.relativeOffset / 60)))
                    }
                }
            }
        }
    }
}
