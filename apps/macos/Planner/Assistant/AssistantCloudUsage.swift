import Foundation

/// Наличие записи отмечает завершённый облачный запрос, даже если сервер не сообщил число токенов.
struct AssistantCloudUsage: Codable, Sendable {
    let tokens: Int?
    var gatewayProfileID: UUID? = nil
}

struct AssistantUsageTotal {
    private(set) var requests = 0
    private(set) var reportedRequests = 0
    private(set) var tokens = 0

    mutating func add(_ usage: AssistantCloudUsage) {
        requests += 1
        if let count = usage.tokens {
            reportedRequests += 1
            tokens += count
        }
    }
}

extension AssistantArchive {
    func cloudUsage(for threadID: UUID?, on date: Date, calendar: Calendar = .current, gatewayProfileID: UUID? = nil)
        -> (conversation: AssistantUsageTotal, today: AssistantUsageTotal) {
        let day = calendar.dateInterval(of: .day, for: date)
        var conversation = AssistantUsageTotal()
        var today = AssistantUsageTotal()
        for thread in threads {
            for message in thread.messages where message.role == .assistant {
                guard let usage = message.cloudUsage, usage.gatewayProfileID == gatewayProfileID else { continue }
                if thread.id == threadID { conversation.add(usage) }
                if let day, message.createdAt >= day.start, message.createdAt < day.end { today.add(usage) }
            }
        }
        return (conversation, today)
    }
}
