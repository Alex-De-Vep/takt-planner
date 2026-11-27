namespace Takt.Core.Assistant;

public sealed record ChatProvider(string Id, string Name, string Protocol, string[] Addresses)
{
    public static IReadOnlyList<ChatProvider> All { get; } =
    [
        new("custom", "Custom API", "openai", []),
        new("chatgpt", "ChatGPT", "openai", ["https://api.openai.com/v1/"]),
        new("openai", "OpenAI API", "openai", ["https://api.openai.com/v1/"]),
        new("openrouter", "OpenRouter API key", "openai", ["https://openrouter.ai/api/v1/"]),
        new("litellm", "LiteLLM", "openai", []),
        new("claude", "Claude", "anthropic", ["https://api.anthropic.com/v1/"]),
        new("gemini", "Gemini", "openai", ["https://generativelanguage.googleapis.com/v1beta/openai/"]),
        new("deepseek", "DeepSeek", "openai", ["https://api.deepseek.com/v1/"]),
        new("mistral", "Mistral", "openai", ["https://api.mistral.ai/v1/"]),
        new("grok", "Grok", "openai", ["https://api.x.ai/v1/"]),
        new("zai", "GLM · Z.ai", "openai", ["https://api.z.ai/api/paas/v4/"]),
        new("minimax", "MiniMax API", "anthropic", ["https://api.minimax.io/anthropic/v1/"]),
        new("minimax-plan", "MiniMax M Plan", "anthropic", ["https://api.minimax.io/anthropic/v1/"]),
        new("qwen", "QwenCloud", "openai",
            new[] { "ap-southeast-1", "eu-central-1", "cn-hongkong", "ap-northeast-1", "us-east-1", "cn-beijing" }
                .Select(region => $"https://{region}.maas.qwencloudapi.com/compatible-mode/v1/").ToArray()),
        new("kimi", "Kimi", "openai", ["https://api.moonshot.ai/v1/", "https://api.moonshot.cn/v1/"]),
        new("yandex", "YandexGPT Pro", "openai", ["https://ai.api.cloud.yandex.net/v1/"]),
        new("giga", "GigaChat", "openai", ["https://api.giga.chat/v1/"]),
        new("copilot", "GitHub Copilot", "openai", ["http://127.0.0.1:43347/v1/"])
    ];
    public static ChatProvider Find(string id) => All.FirstOrDefault(provider => provider.Id == id)
        ?? throw new ArgumentException("Choose a supported AI provider.");
    public static readonly string[] GigaEditions = ["GIGACHAT_API_PERS", "GIGACHAT_API_B2B", "GIGACHAT_API_CORP"];

    public static void Validate(ChatConnection connection, bool requireModel)
    {
        var provider = Find(connection.Provider);
        var address = ChatClient.Address(connection.Address);
        if (provider.Id != "custom" && provider.Protocol != connection.Protocol ||
            provider.Addresses.Length > 0 && !provider.Addresses.Any(value => new Uri(value) == address))
            throw new ArgumentException("Choose an address and API format for the selected provider.");

        if (provider.Id == "yandex")
        {
            string folder = connection.ProviderOption ?? "";
            if (folder.Length is < 1 or > 64 || !folder.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'))
                throw new ArgumentException("Enter the Yandex Cloud folder ID.");
            if (requireModel && !connection.Model.StartsWith($"gpt://{folder}/", StringComparison.Ordinal))
                throw new ArgumentException("Use a Yandex model ID from the selected Cloud folder.");
        }
        if (provider.Id == "giga" && !GigaEditions.Contains(connection.ProviderOption))
            throw new ArgumentException("Choose the GigaChat API edition for your project.");
        if (provider.Id == "copilot" && (requireModel || connection.ProviderOption is not null) &&
            !IsCopilotAccount(connection.ProviderOption))
            throw new ArgumentException("Load the Copilot model catalog to verify the local connection code.");
    }

    public static bool IsCopilotAccount(string? value) => value is { Length: > 2 and <= 256 } &&
        value.Contains('|') && !value.Any(c => char.IsControl(c) || char.IsWhiteSpace(c));
}
