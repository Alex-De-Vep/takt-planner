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
        .accessibilityLabel(strings["Расход"])
        .accessibilityIdentifier("assistant-usage")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            TimelineView(.everyMinute) { timeline in
                let gateway = service.current?.cloud?.gateway
                let profileID = service.current?.cloud?.gatewayProfileID
                let totals = service.archive.cloudUsage(for: service.archive.currentID, on: timeline.date, gatewayProfileID: profileID)
                VStack(alignment: .leading, spacing: 12) {
                    Text(gateway.map { strings.format("Расход %@ в «Задачах»", $0.name) }
                        ?? strings["Расход ChatGPT в «Задачах»"]).font(.headline)
                    usageGroup("В этом чате", totals.conversation)
                    usageGroup("Во всех чатах сегодня", totals.today)
                    Text(strings["По завершённым ответам, сохранённым начиная с этой версии."])
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if totals.conversation.reportedRequests < totals.conversation.requests
                        || totals.today.reportedRequests < totals.today.requests {
                        Text(strings["Для части ответов сервис не сообщил число токенов."])
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let gateway {
                        if gateway == .copilot, service.gatewayProfile != nil, let percent = service.gateways.copilotQuota {
                            Divider()
                            metric("Остаток квоты Copilot", (percent / 100).formatted(.percent.precision(.fractionLength(0...1))))
                        } else if gateway == .miniMaxPlan, service.gatewayProfile != nil,
                                  let model = service.gatewayModel, let percent = service.gateways.miniMaxQuota[model.id] {
                            Divider()
                            metric("Остаток квоты M Plan", (percent / 100).formatted(.percent.precision(.fractionLength(0...1))))
                        } else if service.gatewayProfile != nil, let balance = service.gateways.remaining[gateway] {
                            Divider()
                            metric("Остаток бюджета ключа", balance.formatted(.currency(code: "USD")))
                        }
                    } else {
                        Divider()
                        Link(strings["Открыть лимиты ChatGPT"], destination: ChatGPTHTTP.usageURL)
                    }
                }
                .padding(16)
                .frame(width: 280, alignment: .leading)
            }
            .task(id: [service.gatewayProfile?.id.uuidString, service.gatewayModel?.id]) {
                if let profile = service.gatewayProfile {
                    await service.gateways.refreshBudget(for: profile, modelID: service.gatewayModel?.id)
                }
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
