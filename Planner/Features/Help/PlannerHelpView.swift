import SwiftUI

struct PlannerHelpView: View {
    static let windowID = "planner-help"

    @Environment(\.translations) private var strings
    @State private var selectedID: Int? = 0
    private let chapters: [Chapter]

    init(guide: String?) {
        chapters = (guide ?? "").components(separatedBy: "\n## ").dropFirst().enumerated().compactMap { index, section in
            let lines = section.split(whereSeparator: \.isNewline).map(String.init)
            guard let title = lines.first else { return nil }
            return Chapter(id: index, title: title, lines: Array(lines.dropFirst()))
        }
    }

    var body: some View {
        Group {
            if let chapter = chapters.first(where: { $0.id == selectedID }) ?? chapters.first {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        Section(strings["Разделы справки"]) {
                            ForEach(chapters) { chapter in
                                Text(chapter.title)
                                    .tag(chapter.id)
                                    .accessibilityIdentifier("help-topic-\(chapter.id)")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 218)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(chapter.title)
                                .font(.largeTitle.bold())
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("help-chapter-title")
                                .padding(.bottom, 6)
                            ForEach(Array(chapter.lines.enumerated()), id: \.offset) { _, line in
                                paragraph(line)
                            }
                        }
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(chapter.id)
                }
            } else {
                ContentUnavailableView(strings["Справка недоступна"], systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 660, minHeight: 420)
    }

    @ViewBuilder private func paragraph(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                inlineText(String(line.dropFirst(2)))
            }
        } else {
            inlineText(line)
        }
    }

    private func inlineText(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnly))) ?? AttributedString(text))
    }

    private struct Chapter: Identifiable {
        let id: Int
        let title: String
        let lines: [String]
    }
}
