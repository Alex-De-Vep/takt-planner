import Foundation

extension AssistantCatalogModel {
    var brandLogo: String? {
        switch gateway {
        case nil, .openAI: "ChatGPTLogo"
        case .claude: "BrandAnthropic"
        case .gemini: "BrandGoogle"
        case .miniMax, .miniMaxPlan: "BrandMiniMax"
        case .deepSeek: "BrandDeepSeek"
        case .mistral: "BrandMistral"
        case .glm: "BrandZai"
        case .grok: "BrandXAI"
        case .qwen: "BrandAlibaba"
        case .kimi: "BrandMoonshot"
        case .yandex: "BrandYandex"
        case .gigaChat: "BrandGigaChat"
        case .openRouter, .liteLLM, .copilot: Self.routedLogo(for: modelID)
        }
    }

    private static let vendors = [
        "openai": "ChatGPTLogo", "anthropic": "BrandAnthropic", "google": "BrandGoogle",
        "deepseek": "BrandDeepSeek", "mistralai": "BrandMistral", "x-ai": "BrandXAI",
        "qwen": "BrandAlibaba", "alibaba": "BrandAlibaba", "z-ai": "BrandZai",
        "moonshotai": "BrandMoonshot", "minimax": "BrandMiniMax", "meta-llama": "BrandMeta",
        "microsoft": "BrandMicrosoft", "cohere": "BrandCohere", "nvidia": "BrandNvidia",
        "amazon": "BrandAmazon", "perplexity": "BrandPerplexity", "yandex": "BrandYandex",
        "ai-sage": "BrandGigaChat"
    ]

    private static func routedLogo(for id: String) -> String? {
        let name = id.lowercased()
        if let slash = name.firstIndex(of: "/") {
            return vendors[String(name[..<slash])]
        }
        // Copilot and LiteLLM can return bare model IDs. Unspecified aliases have no known manufacturer.
        let family = name.prefix { $0 != "-" && $0 != ":" && $0 != "." }
        switch family {
        case "gpt", "chatgpt", "o1", "o3", "o4", "codex": return "ChatGPTLogo"
        case "claude": return "BrandAnthropic"
        case "gemini", "gemma": return "BrandGoogle"
        case "grok": return "BrandXAI"
        case "deepseek": return "BrandDeepSeek"
        case "mistral", "mixtral", "codestral", "devstral", "ministral", "pixtral", "magistral": return "BrandMistral"
        case "glm": return "BrandZai"
        case "minimax": return "BrandMiniMax"
        case "kimi", "moonshot": return "BrandMoonshot"
        case "gigachat": return "BrandGigaChat"
        case "yandexgpt": return "BrandYandex"
        case "llama": return "BrandMeta"
        default: return family == "qwen" || (family.hasPrefix("qwen") && family.dropFirst(4).first?.isNumber == true) ? "BrandAlibaba" : nil
        }
    }
}
