import SwiftUI

/// День выбирается в календаре, время редактируется отдельно штатным полем macOS.
struct EventDateTimeRow: View {
    @Environment(\.translations) private var strings
    let title: String
    let dateTitle: String
    let timeTitle: String
    let identifier: String
    @Binding var selection: Date
    let allDay: Bool
    @State private var showingCalendar = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Button { showingCalendar.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text(selection, format: .dateTime.day().month(.abbreviated).year())
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }.frame(width: 175)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(dateTitle)
                .accessibilityValue(Text(selection, format: .dateTime.day().month(.wide).year()))
                .accessibilityIdentifier(identifier + "-date")
                .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(dateTitle).font(.headline)
                        // Увеличиваем и цифры, и область выбора дня, сохраняя нативную сетку macOS.
                        CalendarPickerZoomLayout(scale: 1.2) {
                            DatePicker(dateTitle, selection: Binding(get: { selection }, set: { chooseDay($0) }),
                                       displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                                .fixedSize()
                                .scaleEffect(1.2, anchor: .topLeading)
                        }
                        Button(strings["Сегодня"]) { chooseDay(.now) }
                    }.padding(16)
                }
                if !allDay {
                    DatePicker(timeTitle, selection: $selection, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(timeTitle)
                        .accessibilityIdentifier(identifier + "-time")
                }
            }
        }
    }

    private func chooseDay(_ day: Date) {
        let calendar = Calendar.current
        if !calendar.isDate(day, inSameDayAs: selection) {
            // Выбор дня не сбрасывает заданное время. При переходе на летнее время
            // Calendar подбирает допустимое время, если выбранный час пропущен.
            let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
            selection = allDay ? calendar.startOfDay(for: day)
                : calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                second: time.second ?? 0, of: day) ?? day
        }
        showingCalendar = false
    }
}

/// scaleEffect сам не увеличивает размер для раскладки. Резервируем реальное место,
/// чтобы сетка не обрезалась и не перекрывала кнопку «Сегодня» при любом языке интерфейса.
struct CalendarPickerZoomLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let picker = subviews.first else { return .zero }
        let size = picker.sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}
