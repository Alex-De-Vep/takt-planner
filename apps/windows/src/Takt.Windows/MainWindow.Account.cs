using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Takt.Core.Sync;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private bool accountDialogOpen;
    private string? accountNotice;

    private async Task<(string Origin, string Email)> ShowEmailAccountActionAsync(
        EmailAccountAction action, string address, string emailAddress)
    {
        while (!lifetime.IsCancellationRequested)
        {
            bool reset = action == EmailAccountAction.ResetPassword;
            bool register = action == EmailAccountAction.Register;
            var origin = new TextBox { Header = "Server", Text = address, MaxLength = 2048 };
            var email = new TextBox { Header = "Email", Text = emailAddress, MaxLength = 254,
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.EmailSmtpAddress) } } };
            var firstPassword = new PasswordBox { Header = "Password", MaxLength = 256 };
            var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
            var fields = new StackPanel { Spacing = 12, Children = { origin, email } };
            if (register) fields.Children.Add(firstPassword);
            fields.Children.Add(error);

            string? challenge = null;
            string title = reset ? "Reset password" : register ? "Create a Takt account" : "Verify email";
            var requestDialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = title,
                Content = fields,
                PrimaryButtonText = "Send code",
                CloseButtonText = "Back to sign in",
                DefaultButton = ContentDialogButton.Close
            };
            SubmitAccountForm(requestDialog, error, async () =>
            {
                var selectedOrigin = ApiClient.NormalizeOrigin(origin.Text);
                var selectedEmail = email.Text.Trim();
                challenge = await sync.RequestEmailCodeAsync(selectedOrigin, selectedEmail, action,
                    register ? firstPassword.Password : null, lifetime.Token);
                address = selectedOrigin;
                emailAddress = selectedEmail;
                firstPassword.Password = "";
            });
            ContentDialogResult requestResult;
            try { requestResult = await requestDialog.ShowAsync(); }
            finally { firstPassword.Password = ""; }
            if (requestResult != ContentDialogResult.Primary || challenge is null)
                return (origin.Text, email.Text.Trim());

            var code = new TextBox
            {
                Header = "Eight-digit code",
                MaxLength = 8,
                InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } }
            };
            var password = new PasswordBox { Header = reset ? "New password" : "Password", MaxLength = 256 };
            var detail = new TextBlock
            {
                Text = $"If this address is eligible, Takt sends a code to {emailAddress}. The code expires after 10 minutes.",
                TextWrapping = TextWrapping.Wrap
            };
            var confirmError = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
            var confirm = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = reset ? "Choose a new password" : "Confirm your email",
                Content = new StackPanel { Spacing = 12, Children = { detail, code, password, confirmError } },
                PrimaryButtonText = reset ? "Reset password" : "Verify email",
                SecondaryButtonText = "Request another code",
                CloseButtonText = "Back to sign in",
                DefaultButton = ContentDialogButton.Close
            };
            SubmitAccountForm(confirm, confirmError, async () =>
            {
                await sync.ConfirmEmailCodeAsync(address, challenge, code.Text.Trim(), password.Password, action, lifetime.Token);
            });
            ContentDialogResult result;
            try { result = await confirm.ShowAsync(); }
            finally { code.Text = ""; password.Password = ""; }

            if (result == ContentDialogResult.Primary)
            {
                accountNotice = reset ? "Password reset. Sign in with your new password."
                    : "Email verified. Sign in to open or create your cloud library.";
                return (address, emailAddress);
            }
            if (result != ContentDialogResult.Secondary) return (address, emailAddress);
            if (register) action = EmailAccountAction.Verify;
        }
        return (address, emailAddress);
    }

    private static void SubmitAccountForm(ContentDialog dialog, InfoBar error, Func<Task> submit)
    {
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            error.IsOpen = false;
            try
            {
                await submit();
                args.Cancel = false;
            }
            catch (Exception failure)
            {
                error.Message = Message(failure);
                error.IsOpen = true;
            }
            finally
            {
                dialog.IsPrimaryButtonEnabled = true;
                dialog.IsSecondaryButtonEnabled = true;
                deferral.Complete();
            }
        };
    }
}
