using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Assistant;
using Takt.Windows.Services;
using global::Windows.ApplicationModel.DataTransfer;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace
{
    private async void Settings_Click(object sender, RoutedEventArgs e) => await Guard(ShowSettingsAsync);
    public async Task ShowSettingsAsync()
    {
        if (IsBusy) return;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        settingsOperation = finished.Task; UpdateControls(); RenderMessages();
        try { await ShowSettingsCoreAsync(); }
        finally
        {
            settingsOperation = null;
            try { UpdateControls(); RenderMessages(); }
            finally { finished.TrySetResult(); }
        }
    }
    private async Task ShowSettingsCoreAsync()
    {
        long version = stopVersion;
        var selected = settings.Connections.FirstOrDefault(c => c.Id == settings.SelectedConnection);
        var choices = new ComboBox { Header = "Saved connection", DisplayMemberPath = "DisplayName", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = settings.Connections, SelectedItem = selected };
        var name = new TextBox { Header = "Connection name", MaxLength = 120 };
        var address = new TextBox { Header = "API base address", PlaceholderText = "https://provider.example/v1", MaxLength = 2048 };
        var protocol = new ComboBox { Header = "API format", ItemsSource = new[] { "OpenAI compatible", "Anthropic" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var providerPicker = new ComboBox { Header = "Provider", ItemsSource = ChatProvider.All, DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
        var region = new ComboBox { Header = "API region", HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visibility.Collapsed };
        var project = new TextBox { Header = "Yandex Cloud folder ID", MaxLength = 64, Visibility = Visibility.Collapsed };
        var edition = new ComboBox { Header = "GigaChat API edition", ItemsSource = new[] { "Personal", "Business", "Corporate" }, Visibility = Visibility.Collapsed };
        var copilot = new Button { Content = "Copy Copilot launch command", Visibility = Visibility.Collapsed };
        var key = new PasswordBox { Header = "API key (leave empty to keep the saved key)", MaxLength = 8192 };
        var models = new TextBox { Header = "Selected model IDs (one per line)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 180, MaxLength = 52000 };
        var tools = new CheckBox { Content = "Enable proposals for models that support tools", IsChecked = true };
        var load = new Button { Content = "Load model catalog" };
        var catalog = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 180, Visibility = Visibility.Collapsed };
        var addModels = new Button { Content = "Add selected models", Visibility = Visibility.Collapsed };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var add = new Button { Content = "New connection" }; var remove = new Button { Content = "Remove selected connection" };
        var defaultProvider = ChatProvider.Find("custom");
        bool loading = false;
        string? verifiedCopilotAccount = null;
        ChatProvider Provider() => providerPicker.SelectedItem as ChatProvider ?? defaultProvider;
        void ConfigureProvider(ChatProvider chosen, ChatConnection? existing)
        {
            address.Visibility = chosen.Addresses.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            protocol.Visibility = chosen.Id == "custom" ? Visibility.Visible : Visibility.Collapsed;
            region.Visibility = chosen.Addresses.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
            project.Visibility = chosen.Id == "yandex" ? Visibility.Visible : Visibility.Collapsed;
            edition.Visibility = chosen.Id == "giga" ? Visibility.Visible : Visibility.Collapsed;
            copilot.Visibility = chosen.Id == "copilot" ? Visibility.Visible : Visibility.Collapsed;
            region.ItemsSource = chosen.Addresses;
            region.SelectedItem = existing is not null && chosen.Addresses.Contains(existing.Address) ? existing.Address : chosen.Addresses.FirstOrDefault();
            project.Text = chosen.Id == "yandex" ? existing?.ProviderOption ?? "" : "";
            edition.SelectedIndex = Math.Max(0, Array.IndexOf(ChatProvider.GigaEditions, existing?.ProviderOption));
            verifiedCopilotAccount = chosen.Id == "copilot" ? existing?.ProviderOption : null;
            address.Text = chosen.Addresses.Length == 0 ? existing?.Address ?? "" : "";
            protocol.SelectedIndex = (existing?.Protocol ?? chosen.Protocol) == "anthropic" ? 1 : 0;
            key.Visibility = chosen.Id == "chatgpt" ? Visibility.Collapsed : Visibility.Visible;
            key.Header = chosen.Id switch
            {
                "copilot" => "Local connection code",
                "giga" => "GigaChat Authorization Key",
                "minimax-plan" => "M Plan subscription key",
                _ => "API key (empty keeps the saved key for this connection)"
            };
            catalog.ItemsSource = null;
            catalog.Visibility = addModels.Visibility = Visibility.Collapsed;
        }
        void Load(SavedChatConnection? item)
        {
            loading = true;
            try
            {
                selected = item;
                var chosen = item is null ? defaultProvider : ChatProvider.Find(item.Connection.Provider);
                providerPicker.SelectedItem = chosen;
                ConfigureProvider(chosen, item?.Connection);
                name.Text = item?.Connection.Name ?? "";
                key.Password = "";
                models.Text = item is null ? "" : string.Join("\n", item.Models);
                tools.IsChecked = item?.Connection.Tools ?? true;
                remove.IsEnabled = item is not null;
                error.Text = "";
            }
            finally { loading = false; }
        }
        Load(selected); choices.SelectionChanged += (_, _) => Load(choices.SelectedItem as SavedChatConnection);
        add.Click += (_, _) => { choices.SelectedItem = null; Load(null); };
        providerPicker.SelectionChanged += (_, _) =>
        {
            if (loading) return;
            var chosen = Provider();
            ConfigureProvider(chosen, null);
            name.Text = chosen.Id == "custom" ? "" : chosen.Name;
            key.Password = models.Text = "";
            error.Text = "";
        };
        copilot.Click += (_, _) =>
        {
            string path = Path.Combine(AppContext.BaseDirectory, "CopilotBridge", "start.ps1").Replace("'", "''");
            var content = new DataPackage();
            content.SetText("& '" + path + "'");
            Clipboard.SetContent(content);
            error.Text = "Paste the command in PowerShell. Sign in when prompted, then copy the connection code from the terminal.";
        };
        bool removeRequested = false, openRouterRequested = false, chatGptRequested = false, renewChatGpt = false;
        var openRouter = new Button { Content = "Continue with OpenRouter…" };
        var chatGptSignIn = new Button { Content = "Continue with ChatGPT" };
        var chatGptRenew = new Button { Content = "Renew selected ChatGPT account" };
        void UpdateRenew() => chatGptRenew.Visibility = selected?.Connection.Provider == "chatgpt" && Provider().Id == "chatgpt" ? Visibility.Visible : Visibility.Collapsed;
        UpdateRenew();
        choices.SelectionChanged += (_, _) => UpdateRenew();
        providerPicker.SelectionChanged += (_, _) => UpdateRenew();
        var panel = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = "Connect ChatGPT or OpenRouter in your browser, or configure another provider below. Choose the provider before adding a key. Load models from its catalog or enter model IDs from your account.", TextWrapping = TextWrapping.Wrap }, chatGptSignIn, openRouter, choices, chatGptRenew, add, providerPicker, region, name, address, protocol, project, edition, copilot, key, tools, models, load, catalog, addModels, remove, error } };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "AI connections and models", Content = new ScrollViewer { Content = panel, MaxHeight = 620 }, PrimaryButtonText = "Save connection", CloseButtonText = "Cancel" };
        remove.Click += (_, _) => { removeRequested = true; dialog.Hide(); };
        openRouter.Click += (_, _) => { openRouterRequested = true; dialog.Hide(); };
        chatGptSignIn.Click += (_, _) => { chatGptRequested = true; dialog.Hide(); };
        chatGptRenew.Click += (_, _) => { chatGptRequested = renewChatGpt = true; dialog.Hide(); };
        using var catalogCancellation = new CancellationTokenSource(); settingsCancellation = catalogCancellation; bool catalogBusy = false;
        string CurrentKey(ChatConnection connection)
        {
            if (key.Password.Length > 0) return key.Password;
            if (selected is not { Connection: var previous }) return "";
            bool same = ChatClient.Address(connection.Address) == ChatClient.Address(previous.Address) &&
                connection.Protocol == previous.Protocol && connection.Provider == previous.Provider && connection.ProviderOption == previous.ProviderOption;
            return same ? selected.Key() : "";
        }
        ChatConnection CurrentConnection()
        {
            var chosen = Provider();
            string api = chosen.Addresses.Length == 0 ? address.Text.Trim() : region.SelectedItem as string ?? chosen.Addresses[0];
            string? option = chosen.Id switch
            {
                "yandex" => project.Text.Trim(),
                "giga" => ChatProvider.GigaEditions[Math.Clamp(edition.SelectedIndex, 0, ChatProvider.GigaEditions.Length - 1)],
                "copilot" => verifiedCopilotAccount,
                "chatgpt" => selected?.Connection.Provider == "chatgpt" ? selected.Connection.ProviderOption : null,
                _ => null
            };
            return new(name.Text.Trim(), ChatClient.Address(api).AbsoluteUri,
                models.Text.Split('\n').Select(model => model.Trim()).FirstOrDefault(model => model.Length > 0) ?? "",
                tools.IsChecked == true, chosen.Id == "custom" && protocol.SelectedIndex == 1 ? "anthropic" : chosen.Protocol, chosen.Id, option);
        }
        var formControls = new Control[] { choices, add, remove, openRouter, chatGptSignIn, chatGptRenew, providerPicker, region, name, address, protocol, project, edition, copilot, key, tools, models };
        load.Click += async (_, _) =>
        {
            if (catalogBusy) return;
            var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); settingsRequest = finished.Task;
            catalogBusy = true; load.IsEnabled = false; dialog.IsPrimaryButtonEnabled = false; error.Text = "Loading catalog…";
            foreach (var field in formControls) field.IsEnabled = false;
            try
            {
                var connection = CurrentConnection();
                string secret = connection.Provider == "chatgpt"
                    ? await ConnectionKeyAsync(selected is { Connection.Provider: "chatgpt" } ? selected
                        : throw new ReviewFailure("Use Continue with ChatGPT first."), catalogCancellation.Token)
                    : CurrentKey(connection);
                if (connection.Provider == "chatgpt" && selected is not null)
                    selected = settings.Connections.FirstOrDefault(item => item.Id == selected.Id) ?? selected;
                if (connection.Provider == "copilot")
                {
                    verifiedCopilotAccount = await client.VerifyCopilotAsync(connection with { ProviderOption = null }, secret, catalogCancellation.Token);
                    connection = connection with { ProviderOption = verifiedCopilotAccount };
                }
                var available = await client.ModelsAsync(connection, secret, catalogCancellation.Token);
                catalog.ItemsSource = available;
                if (connection.Provider == "yandex" && models.Text.Length == 0)
                    models.Text = string.Join("\n", available);
                catalog.Visibility = addModels.Visibility = Visibility.Visible;
                error.Text = "Select models from the catalog, or enter their IDs manually.";
            }
            catch (OperationCanceledException) { }
            catch (Exception) { error.Text = "The catalog could not be loaded. Check the address, key and API format, or enter model IDs manually."; }
            finally { catalogBusy = false; settingsRequest = null; try { load.IsEnabled = true; dialog.IsPrimaryButtonEnabled = true; foreach (var field in formControls) field.IsEnabled = true; remove.IsEnabled = selected is not null; } finally { finished.TrySetResult(); } }
        };
        addModels.Click += (_, _) => { var all = models.Text.Split('\n').Concat(catalog.SelectedItems.Cast<string>()).Select(m => m.Trim()).Where(m => m.Length > 0).Distinct(StringComparer.Ordinal); models.Text = string.Join("\n", all); };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                if (catalogBusy) throw new ArgumentException("Wait for the model catalog or close this dialog.");
                if (selected is null && settings.Connections.Length >= 30) throw new ArgumentException("Remove a connection before adding more than 30.");
                var connection = CurrentConnection();
                var modelIds = models.Text.Split('\n');
                var entry = connection.Provider == "chatgpt"
                    ? SavedChatConnection.CreateChatGpt(selected?.Id, connection, modelIds, selected is { Connection.Provider: "chatgpt" }
                        ? selected.ChatGpt() : throw new ArgumentException("Use Continue with ChatGPT first."))
                    : SavedChatConnection.Create(selected?.Id, connection, modelIds, CurrentKey(connection));
                var next = settings with { Connections = settings.Connections.Where(c => c.Id != entry.Id).Append(entry).ToArray(), SelectedConnection = entry.Id, SelectedModel = entry.Connection.Model };
                next.Save(directory); settings = next;
            }
            catch (Exception failure) { args.Cancel = true; error.Text = failure is ArgumentException or InvalidDataException ? failure.Message : "The connection could not be saved. Existing settings and protected keys have been kept."; }
        };
        try
        {
            activeDialog = dialog; await dialog.ShowAsync(); if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; catalogCancellation.Cancel();
            if (settingsRequest is { } pending) await pending;
            if (version == stopVersion && chatGptRequested) { key.Password = ""; await ConnectBrowserAsync(version, true, renewChatGpt ? selected : null); return; }
            if (version == stopVersion && openRouterRequested) { key.Password = ""; await ConnectOpenRouterAsync(version); return; }
            if (version == stopVersion && removeRequested && selected is not null && await ConfirmAsync("Remove connection?", "Remove this connection and its protected API key from this Windows device? Conversation history will be kept.", "Remove connection") && version == stopVersion)
            {
                var next = settings with { Connections = settings.Connections.Where(c => c.Id != selected.Id).ToArray(), SelectedConnection = null, SelectedModel = null };
                next.Save(directory); settings = next;
            }
        }
        finally { catalogCancellation.Cancel(); if (settingsRequest is { } pending) await pending; settingsCancellation = null; if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; key.Password = ""; RefreshPickers(); }
    }
}
