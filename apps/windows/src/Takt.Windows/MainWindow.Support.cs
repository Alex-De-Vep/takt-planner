using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Models;
using Takt.Core.Sync;
using Takt.Windows.Services;
using global::Windows.ApplicationModel.DataTransfer;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private bool supportDialogOpen;

    private async void Support_Click(object sender, RoutedEventArgs e) => await Guard(ShowSupportAsync);

    private async Task ShowSupportAsync()
    {
        if (!ready || closing || supportDialogOpen) return;
        supportDialogOpen = true;
        try
        {
            var profile = (await store.ConnectionAsync())?.Profile;
            if (profile is null)
            {
                if (!await ConfirmAsync("Sign in to contact support", "Use your Takt account to get a receipt for your request.", "Open account"))
                    return;
                await ShowAccountAsync();
                profile = (await store.ConnectionAsync())?.Profile;
                if (profile is null || closing) return;
            }

            var draftStore = new SupportDraft(profile.Workspace);
            var pending = draftStore.Read();
            var subject = new TextBox { Header = "Subject (optional)", MaxLength = 240, Text = pending?.Subject ?? "" };
            var message = new TextBox
            {
                Header = "How can we help?",
                Text = pending?.Message ?? "",
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                MaxLength = 8000,
                MinHeight = 120,
                MaxHeight = 260
            };
            var replyEmail = new TextBox { Header = "Reply email (optional)", PlaceholderText = profile.Email, Text = pending?.ReplyEmail ?? "", MaxLength = 254 };
            var notice = new TextBlock
            {
                Text = "Your request includes the Takt version, Windows version and the current time on your device with its UTC offset.",
                TextWrapping = TextWrapping.Wrap
            };
            var retry = new TextBlock
            {
                Text = "A pending request was restored. Send it unchanged to recover the same receipt. Editing its details starts a new request.",
                TextWrapping = TextWrapping.Wrap,
                Visibility = pending is null ? Visibility.Collapsed : Visibility.Visible
            };
            var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
            var fields = new StackPanel { Spacing = 12, Children = { notice, retry, subject, message, replyEmail, error } };
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "Contact Takt support",
                Content = new ScrollViewer { Content = fields, MaxHeight = 560 },
                PrimaryButtonText = "Send request",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close
            };
            SupportReceipt? receipt = null;
            bool draftCleared = true;
            SubmitAccountForm(dialog, error, async () =>
            {
                subject.IsReadOnly = message.IsReadOnly = replyEmail.IsReadOnly = true;
                try
                {
                    string? subjectText = OptionalField(subject.Text), reply = OptionalField(replyEmail.Text);
                    string messageText = message.Text.Trim();
                    SupportRequest.ValidateContent(subjectText, messageText, reply);
                    if (pending is null || pending.Subject != subjectText || pending.Message != messageText || pending.ReplyEmail != reply)
                    {
                        var version = typeof(MainWindow).Assembly.GetName().Version ?? new Version(1, 0);
                        var request = new SupportRequest(Wire.Id(), subjectText, messageText, reply, "windows",
                            version.ToString(), Math.Max(0, version.Revision).ToString(System.Globalization.CultureInfo.InvariantCulture),
                            Environment.OSVersion.Version.ToString(), DateTimeOffset.Now);
                        request.ValidatePayload();
                        draftStore.Save(request);
                        pending = request;
                    }
                    retry.Visibility = Visibility.Visible;
                    receipt = await sync.SubmitSupportAsync(profile, pending, lifetime.Token);
                    try { draftStore.Clear(); }
                    catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { draftCleared = false; }
                }
                finally { subject.IsReadOnly = message.IsReadOnly = replyEmail.IsReadOnly = false; }
            });
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || receipt is null || closing) return;
            await ShowSupportReceiptAsync(receipt, draftCleared);
        }
        finally { supportDialogOpen = false; }
    }

    private static string? OptionalField(string text) => text.Trim() is { Length: > 0 } value ? value : null;

    private async Task ShowSupportReceiptAsync(SupportReceipt receipt, bool draftCleared)
    {
        var code = new TextBlock { Text = receipt.Code, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, IsTextSelectionEnabled = true };
        var status = new TextBlock
        {
            Text = draftCleared ? "The server accepted your request. Keep this code for reference."
                : "The server accepted your request. The local draft could not be cleared. Sending it unchanged returns this same code.",
            TextWrapping = TextWrapping.Wrap
        };
        var copy = new Button { Content = "Copy code" };
        copy.Click += (_, _) =>
        {
            var data = new DataPackage();
            data.SetText(receipt.Code);
            Clipboard.SetContent(data);
            copy.Content = "Code copied";
        };
        await new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "Request received",
            Content = new StackPanel { Spacing = 12, Children = { status, code, copy } },
            CloseButtonText = "Done"
        }.ShowAsync();
    }
}
