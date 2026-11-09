import SwiftUI

struct AssistantUsageButton: View {
    @Environment(\.translations) private var strings
    @State private var expanded = false
    let service: AssistantService

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "chart.bar").font(.caption).padding(4)
        }
        .buttonStyle(.borderless)
        .help(strings["Расход"])
        .accessibilityLabel(strings["Расход ChatGPT"])
        .accessibilityIdentifier("assistant-usage")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            TimelineView(.everyMinute) { timeline in
                let totals = service.archive.cloudUsage(for: service.archive.currentID, on: timeline.date)
                VStack(alignment: .leading, spacing: 12) {
                    Text(strings["Расход ChatGPT в «Задачах»"]).font(.headline)
                    usageGroup("В этом чате", totals.conversation)
                    usageGroup("Во всех чатах сегодня", totals.today)
                    Text(strings["По завершённым ответам, сохранённым начиная с этой версии."])
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if totals.conversation.reportedRequests < totals.conversation.requests
                        || totals.today.reportedRequests < totals.today.requests {
                        Text(strings["Для части ответов ChatGPT не сообщил число токенов."])
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Link(strings["Открыть лимиты ChatGPT"], destination: ChatGPTHTTP.usageURL)
                }
                .padding(16)
                .frame(width: 280, alignment: .leading)
            }
        }
    }

    private func usageGroup(_ title: String, _ total: AssistantUsageTotal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strings[title]).fontWeight(.medium)
            metric("Запросы", total.requests.formatted())
            metric("Токены", tokenLabel(total))
        }
    }

    private func tokenLabel(_ total: AssistantUsageTotal) -> String {
        if total.requests == 0 { return 0.formatted() }
        if total.reportedRequests == 0 { return "—" }
        let value = total.tokens.formatted()
        return total.reportedRequests < total.requests ? "≥ " + value : value
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(strings[label]).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
