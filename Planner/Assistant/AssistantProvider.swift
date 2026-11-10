import Foundation

enum AssistantGateway: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter, liteLLM, copilot, miniMaxPlan, miniMax, claude, gemini, deepSeek, mistral, glm, grok, qwen, kimi, yandex, gigaChat

    enum Wire: Equatable { case chat, responses, messages }

    var id: Self { self }
    var name: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .liteLLM: "LiteLLM"
        case .copilot: "GitHub Copilot"
        case .miniMaxPlan: "MiniMax M Plan"
        case .miniMax: "MiniMax API"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .mistral: "Mistral"
        case .glm: "GLM · Z.ai"
        case .grok: "Grok"
        case .qwen: "QwenCloud"
        case .kimi: "Kimi"
        case .yandex: "YandexGPT Pro"
        case .gigaChat: "GigaChat"
        }
    }

    var wire: Wire {
        switch self {
        case .claude, .miniMax, .miniMaxPlan: .messages
        case .deepSeek, .mistral, .grok: .responses
        default: .chat
        }
    }

    var endpoint: String {
        switch wire {
        case .chat: "chat/completions"
        case .messages: "messages"
        case .responses: "responses"
        }
    }

    var bases: [URL] {
        let addresses: [String]
        switch self {
        case .openRouter: addresses = ["https://openrouter.ai/api/v1"]
        case .liteLLM: addresses = []
        case .copilot: addresses = ["http://127.0.0.1:43347/v1"]
        case .miniMax, .miniMaxPlan: addresses = ["https://api.minimax.io/anthropic/v1"]
        case .claude: addresses = ["https://api.anthropic.com/v1"]
        case .gemini: addresses = ["https://generativelanguage.googleapis.com/v1beta/openai"]
        case .deepSeek: addresses = ["https://api.deepseek.com"]
        case .mistral: addresses = ["https://api.mistral.ai/v1"]
        case .glm: addresses = ["https://api.z.ai/api/paas/v4"]
        case .grok: addresses = ["https://api.x.ai/v1"]
        case .qwen:
            addresses = ["ap-southeast-1", "eu-central-1", "cn-hongkong", "ap-northeast-1", "us-east-1", "cn-beijing"].map {
                "https://\($0).maas.qwencloudapi.com/compatible-mode/v1"
            }
        case .kimi: addresses = ["https://api.moonshot.ai/v1", "https://api.moonshot.cn/v1"]
        case .yandex: addresses = ["https://ai.api.cloud.yandex.net/v1"]
        case .gigaChat: addresses = ["https://api.giga.chat/v1"]
        }
        return addresses.compactMap { URL(string: $0) }
    }

    func permits(_ base: URL) -> Bool {
        self == .liteLLM ? AssistantGatewayProfile.liteLLMBase(base.absoluteString) == base : bases.contains(base)
    }

    /// Эти API не публикуют совместимый каталог для клиентского ключа.
    var configuredCatalog: Bool { [.miniMax, .miniMaxPlan, .glm, .qwen, .yandex].contains(self) }

    var suggestedIDs: [String] {
        switch self {
        case .miniMax, .miniMaxPlan: ["MiniMax-M3.1-Flash", "MiniMax-M3"]
        case .glm: ["glm-5", "glm-4.7"]
        case .qwen: ["qwen3.8-max", "qwen-plus", "qwen-flash"]
        default: []
        }
    }

    var isMiniMax: Bool { self == .miniMax || self == .miniMaxPlan }

    var supportsKeyBudget: Bool { self == .openRouter || self == .liteLLM }
    var keyPage: URL? {
        let address: String?
        switch self {
        case .miniMaxPlan: address = "https://www.minimax.io/m-plan"
        case .miniMax: address = "https://platform.minimax.io/user-center/basic-information/interface-key"
        case .claude: address = "https://platform.claude.com/settings/keys"
        case .gemini: address = "https://aistudio.google.com/apikey"
        case .deepSeek: address = "https://platform.deepseek.com/api_keys"
        case .mistral: address = "https://console.mistral.ai/api-keys"
        case .glm: address = "https://z.ai/manage-apikey/apikey-list"
        case .grok: address = "https://console.x.ai/"
        case .qwen: address = "https://console.qwencloud.com/"
        case .kimi: address = "https://platform.moonshot.ai/console/api-keys"
        case .yandex: address = "https://console.yandex.cloud/"
        case .gigaChat: address = "https://developers.sber.ru/studio/"
        default: address = nil
        }
        return address.flatMap { URL(string: $0) }
    }

    func documentedTools(_ id: String) -> Bool? {
        let name = id.lowercased()
        switch self {
        case .claude: return name.hasPrefix("claude-")
        case .yandex, .copilot: return true
        case .gigaChat: return name.hasPrefix("gigachat")
        case .gemini: return name.hasPrefix("gemini-") && !["image", "tts", "live", "audio", "robotics", "deep-research"].contains { name.contains($0) }
        case .deepSeek: return name.hasPrefix("deepseek-") ? true : nil
        case .grok: return name.hasPrefix("grok-") ? true : nil
        case .miniMax, .miniMaxPlan, .glm, .qwen: return suggestedIDs.contains(id) ? true : nil
        case .kimi: return (name.hasPrefix("kimi-k2") || name.hasPrefix("moonshot-v1")) ? true : nil
        default: return nil
        }
    }
}


enum GigaChatScope: String, Codable, CaseIterable, Identifiable {
    case personal = "GIGACHAT_API_PERS"
    case business = "GIGACHAT_API_B2B"
    case corporate = "GIGACHAT_API_CORP"

    var id: Self { self }

    var label: String {
        switch self {
        case .personal: "Для физических лиц"
        case .business: "Для бизнеса (B2B)"
        case .corporate: "Корпоративный (CORP)"
        }
    }
}
