import SwiftUI
import WidgetKit

@main
struct QuickActionsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CreateNoteWidget()
        CreateEventWidget()
    }
}

struct CreateNoteWidget: Widget {
    var body: some WidgetConfiguration { quickActionConfiguration(.newNote) }
}

struct CreateEventWidget: Widget {
    var body: some WidgetConfiguration { quickActionConfiguration(.newEvent) }
}

@MainActor private func quickActionConfiguration(_ action: WidgetQuickAction) -> some WidgetConfiguration {
    StaticConfiguration(kind: action.kind, provider: QuickActionProvider()) { _ in
        QuickActionWidgetView(action: action)
    }
    .configurationDisplayName(action.title)
    .description(action.summary)
    .supportedFamilies([.systemSmall])
}

private struct QuickActionEntry: TimelineEntry {
    let date: Date
}

private struct QuickActionProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionEntry {
        QuickActionEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

private struct QuickActionWidgetView: View {
    let action: WidgetQuickAction
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: action.symbol)
                .font(.system(size: 32, weight: .medium))
                .widgetAccentable()
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(action.title)
                .font(.headline)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(renderingMode == .fullColor ? Color.white : Color.primary)
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                LinearGradient(colors: action.background, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
        .widgetURL(action.url)
    }
}

private extension WidgetQuickAction {
    var title: LocalizedStringKey {
        switch self {
        case .newNote: "Create Note"
        case .newEvent: "Create Event"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .newNote: "Start a new note in Takt."
        case .newEvent: "Open the new calendar event form in Takt."
        }
    }

    var symbol: String {
        switch self {
        case .newNote: "square.and.pencil"
        case .newEvent: "calendar.badge.plus"
        }
    }

    var background: [Color] {
        switch self {
        case .newNote: [Color(red: 0.659, green: 0.914, blue: 0.824),
                        Color(red: 0.482, green: 0.784, blue: 0.671)]
        case .newEvent: [Color(red: 0.271, green: 0.435, blue: 0.686),
                         Color(red: 0.133, green: 0.247, blue: 0.455)]
        }
    }
}
