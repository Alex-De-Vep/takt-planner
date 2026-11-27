using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Assistant;
using Takt.Windows.Services;
using global::Windows.System;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace
{
    private Task ConnectOpenRouterAsync(long version) => ConnectBrowserAsync(version, false, null);

    private async Task ConnectBrowserAsync(long version, bool useChatGpt, SavedChatConnection? previous)
    {
        string providerName = useChatGpt ? "ChatGPT" : "OpenRouter";
        if (previous is null && settings.Connections.Length >= 30) throw new ReviewFailure("Remove an unused connection before adding another account.");
        using var stop = new CancellationTokenSource();
        settingsCancellation = stop;
        var progress = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Connect " + providerName,
            Content = new StackPanel { Spacing = 12, Children =
            {
                new ProgressRing { IsActive = true, Width = 28, Height = 28 },
                new TextBlock { Text = "Continue in your browser, then return to Takt. Your credentials are protected on this Windows device. No chat message is sent by connecting.", TextWrapping = TextWrapping.Wrap, MaxWidth = 360 }
            } }, CloseButtonText = "Cancel"
        };
        progress.CloseButtonClick += (_, _) => stop.Cancel();
        Task<ContentDialogResult>? shown = null;
        try
        {
            activeDialog = progress;
            shown = ShowDialogResultAsync(progress);
            if (shown.IsCompleted)
            {
                await shown; stop.Cancel(); return;
            }
            ChatGptCredential? chatGptCredential = null;
            string authorization;
            var address = useChatGpt ? "https://api.openai.com/v1/" : "https://openrouter.ai/api/v1/";
            var connection = new ChatConnection(providerName, address, "", Provider: useChatGpt ? "chatgpt" : "openrouter");
            IReadOnlyList<string> available = [];
            string catalogProblem = "";
            async Task OpenBrowser(Uri uri)
            {
                if (version != stopVersion) throw new OperationCanceledException();
                if (!await Launcher.LaunchUriAsync(uri)) throw new ReviewFailure("Windows could not open the default browser.");
            }
            try
            {
                if (useChatGpt)
                {
                    chatGptCredential = await chatGpt.SignInAsync(ChatGptHostId(), previous?.ChatGpt(), OpenBrowser, stop.Token);
                    connection = connection with { ProviderOption = chatGptCredential.ClientId };
                    authorization = chatGptCredential.AccessToken;
                }
                else authorization = (await new OpenRouterOAuth().ConnectAsync(OpenBrowser, stop.Token)).Key;
                stop.Token.ThrowIfCancellationRequested();
                if (version != stopVersion) throw new OperationCanceledException();
                try { available = await client.ModelsAsync(connection, authorization, stop.Token); }
                catch (OperationCanceledException) { throw; }
                catch (Exception) { catalogProblem = "The catalog could not be loaded. Enter model IDs available to the authorized account."; }
            }
            finally
            {
                progress.Hide(); await shown;
                if (ReferenceEquals(activeDialog, progress)) activeDialog = null;
            }
            stop.Token.ThrowIfCancellationRequested();
            if (version != stopVersion) return;
            string name = previous?.Connection.Name ?? (chatGptCredential?.Email is { } email && email.Length <= 106
                ? providerName + " · " + email : providerName);
            var names = new TextBox { Header = "Connection name", Text = name, MaxLength = 120 };
            var models = new ListView { ItemsSource = available, SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 240 };
            var manual = new TextBox { Header = "Additional model IDs (one per line)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 140, MaxLength = 26000 };
            if (previous is not null) manual.Text = string.Join("\n", previous.Models);
            var tools = new CheckBox { Content = "Enable reviewed proposals for models with tool support", IsChecked = previous?.Connection.Tools ?? true };
            var error = new TextBlock { Text = catalogProblem, TextWrapping = TextWrapping.Wrap };
            var select = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Choose " + providerName + " models",
                Content = new ScrollViewer { MaxHeight = 580, Content = new StackPanel { Spacing = 12, Children =
                {
                    new TextBlock { Text = "Choose models available to your authorized account.", TextWrapping = TextWrapping.Wrap },
                    names, models, manual, tools, error
                } } }, PrimaryButtonText = "Save connection", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
            };
            select.PrimaryButtonClick += (_, args) =>
            {
                try
                {
                    if (version != stopVersion) throw new OperationCanceledException();
                    var selected = models.SelectedItems.Cast<string>().Concat(manual.Text.Split('\n')).Select(id => id.Trim()).Where(id => id.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
                    var configured = connection with { Name = names.Text, Model = selected.FirstOrDefault() ?? "", Tools = tools.IsChecked == true };
                    var entry = chatGptCredential is null
                        ? SavedChatConnection.Create(null, configured, selected, authorization)
                        : SavedChatConnection.CreateChatGpt(previous?.Id, configured, selected, chatGptCredential);
                    var next = settings with { Connections = settings.Connections.Where(item => item.Id != entry.Id).Append(entry).ToArray(), SelectedConnection = entry.Id, SelectedModel = entry.Connection.Model };
                    next.Save(directory); settings = next;
                }
                catch (Exception failure)
                {
                    args.Cancel = true;
                    error.Text = failure is ArgumentException or InvalidDataException ? failure.Message : "The protected connection could not be saved. Existing connections have been kept.";
                }
            };
            activeDialog = select;
            try { await select.ShowAsync(); }
            finally { if (ReferenceEquals(activeDialog, select)) activeDialog = null; }
        }
        catch (OperationCanceledException) { Problem("Connection cancelled", "The connection was not saved on this device."); }
        catch (Exception error) when (error is TimeoutException or InvalidOperationException or InvalidDataException or ReviewFailure)
        { Problem(providerName + " connection could not finish", error.Message); }
        finally
        {
            stop.Cancel(); settingsCancellation = null;
            if (ReferenceEquals(activeDialog, progress)) activeDialog = null;
            RefreshPickers();
        }
    }
    private static async Task<ContentDialogResult> ShowDialogResultAsync(ContentDialog dialog) => await dialog.ShowAsync();
}
