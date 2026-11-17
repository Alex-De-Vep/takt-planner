import OSLog
import SwiftUI
import WidgetKit

@main
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodayWidgetSnapshot.kind, provider: TodayProvider()) { entry in
            TodayWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Today")
        .description("See the tasks you starred in Takt.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: TodayWidgetSnapshot?
}

private struct TodayProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "local.planner.Planner.TodayWidget", category: "TodayWidget")

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: .init(count: 3, rows: [
            .init(id: UUID(), title: String(localized: "Review plans"), deadline: nil),
            .init(id: UUID(), title: String(localized: "Prepare notes"), deadline: nil),
            .init(id: UUID(), title: String(localized: "Send an update"), deadline: nil),
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = currentEntry()
        // Takt asks for a reload as soon as the active library changes.
        let next = entry.date.addingTimeInterval(entry.snapshot == nil ? 15 * 60 : 60 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> TodayEntry {
        guard let url = TodayWidgetSnapshot.fileURL else { return TodayEntry(date: .now, snapshot: nil) }
        do {
            let snapshot = try TodayWidgetSnapshot.read(from: url)
            Self.logger.notice("Loaded the Today widget snapshot.")
            return TodayEntry(date: .now, snapshot: snapshot)
        } catch CocoaError.fileReadNoSuchFile {
            return TodayEntry(date: .now, snapshot: nil)
        } catch {
            let failure = error as NSError
            Self.logger.error("Could not read the Today widget snapshot: \(failure.domain, privacy: .public) \(failure.code, privacy: .public).")
            return TodayEntry(date: .now, snapshot: nil)
        }
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let snapshot: TodayWidgetSnapshot?

    private var fullColor: Bool { renderingMode == .fullColor }
    private var primaryInk: Color { fullColor ? .white : .primary }
    private var secondaryInk: Color { fullColor ? .white.opacity(0.91) : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today", systemImage: "star.fill")
                    .font(.headline)
                    .widgetAccentable()
                Spacer(minLength: 4)
                if let snapshot {
                    Text(snapshot.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(secondaryInk)
                        .privacySensitive()
                }
            }
            .lineLimit(1)

            if let snapshot, !snapshot.rows.isEmpty {
                ForEach(snapshot.rows.prefix(family == .systemSmall ? 3 : TodayWidgetSnapshot.rowLimit)) { row in
                    taskRow(row)
                }
            } else {
                Text(snapshot == nil ? LocalizedStringKey("Open Takt to load your tasks.") : "No active tasks.")
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(primaryInk)
        .tint(primaryInk)
        .containerBackground(for: .widget) {
            if fullColor {
                TodayWidgetBackground()
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
    }

    private func taskRow(_ row: TodayWidgetSnapshot.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
            if row.title.isEmpty {
                Text("Untitled task")
            } else {
                Text(row.title)
            }
            Spacer(minLength: 0)
            if family == .systemMedium, let deadline = row.deadline {
                Text(deadline.date, format: deadlineFormat(deadline))
                    .foregroundStyle(secondaryInk)
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .privacySensitive()
    }

    private func deadlineFormat(_ deadline: TodayWidgetSnapshot.Row.Deadline) -> Date.FormatStyle {
        let zone = deadline.includesTime ? .current : TimeZone(identifier: deadline.timeZoneID) ?? .current
        let day = Date.FormatStyle(timeZone: zone).month(.abbreviated).day()
        return deadline.includesTime ? day.hour().minute() : day
    }
}

private struct TodayWidgetBackground: View {
    var body: some View {
        // Start with Takt's violet accent and keep the lettering readable over the highlight.
        LinearGradient(
            colors: [Color(red: 0.463, green: 0.314, blue: 0.710),
                     Color(red: 0.212, green: 0.125, blue: 0.365)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [Color(red: 0.718, green: 0.608, blue: 0.918).opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 180
            )
        }
    }
}
