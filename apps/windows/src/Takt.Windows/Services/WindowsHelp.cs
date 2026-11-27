using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text;
using global::Windows.ApplicationModel.DataTransfer;

namespace Takt.Windows.Services;

public static class WindowsHelp
{
    private const int ByteLimit = 1024 * 1024;
    private sealed record Section(string Title, string Text);
    public static async Task ShowAsync(XamlRoot root)
    {
        string guide; bool unavailable = false;
        try { guide = await ReadAsync(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or DecoderFallbackException)
        {
            unavailable = true;
            guide = "# Takt for Windows\n\n## Getting started\n\nUse Tasks and Notes on the left. Open Calendar or AI chat from the top bar. The welcome screen can also be opened again from the app menu.\n\n## Your data\n\nTasks and current shared-format notes can synchronize with a Takt account. Windows calendar events and chat history stay on this device. AI requests need a configured API connection and your confirmation.\n\n## Bundled guide unavailable\n\nThe full guide could not be read from this installation. Install the current Windows package again to restore Help.md. Your library has not been changed.\n";
        }
        var sections = Sections(guide);
        var picker = new ComboBox { Header = "Guide section", HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = new[] { "All sections" }.Concat(sections.Select(s => s.Title)).ToArray(), SelectedIndex = 0 };
        var content = new StackPanel { Spacing = 8, Padding = new Thickness(0, 0, 8, 8) };
        var reader = new ScrollViewer { Content = content, MaxHeight = 480, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        void Render()
        {
            content.Children.Clear();
            string selected = picker.SelectedIndex <= 0 ? guide : sections[picker.SelectedIndex - 1].Text;
            foreach (var block in Blocks(selected)) content.Children.Add(block);
            reader.ChangeView(null, 0, null, true);
        }
        picker.SelectionChanged += (_, _) => Render(); Render();
        var feedback = new TextBlock { Text = unavailable ? "Showing the short guide because the bundled file is unavailable." : "Select text to copy a paragraph, or copy the complete guide below.", TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Takt for Windows guide", PrimaryButtonText = "Copy guide", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Close,
            Content = new Grid
            {
                RowSpacing = 12, RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }, new RowDefinition { Height = GridLength.Auto } },
                Children = { picker, reader, feedback }
            }
        };
        var layout = (Grid)dialog.Content; Grid.SetRow(layout.Children[1], 1); Grid.SetRow(feedback, 2);
        dialog.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            try { var data = new DataPackage(); data.SetText(guide); Clipboard.SetContent(data); Clipboard.Flush(); feedback.Text = "The complete guide was copied."; }
            catch (Exception) { feedback.Text = "The clipboard is unavailable. Select a paragraph and use Ctrl+C instead."; }
        };
        await dialog.ShowAsync();
    }
    private static async Task<string> ReadAsync()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Help.md");
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length > ByteLimit) throw new InvalidDataException("The bundled guide exceeds its size limit.");
        using var bytes = new MemoryStream(); byte[] block = new byte[8192];
        while (true)
        {
            int count = await file.ReadAsync(block); if (count == 0) break;
            if (bytes.Length + count > ByteLimit) throw new InvalidDataException("The bundled guide exceeds its size limit.");
            bytes.Write(block, 0, count);
        }
        string text = new UTF8Encoding(false, true).GetString(bytes.ToArray()).TrimStart('\uFEFF');
        if (text.Count(c => c == '\n') > 4096) throw new InvalidDataException("The bundled guide contains too many blocks.");
        if (string.IsNullOrWhiteSpace(text)) throw new InvalidDataException("The bundled guide is empty.");
        return text.Replace("\r\n", "\n").Replace('\r', '\n');
    }
    private static List<Section> Sections(string text)
    {
        List<Section> sections = []; string? title = null; StringBuilder body = new();
        foreach (string line in text.Split('\n'))
        {
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                if (title is not null) sections.Add(new(title, body.ToString()));
                title = line[3..].Trim(); body.Clear();
            }
            if (title is not null) body.AppendLine(line);
        }
        if (title is not null) sections.Add(new(title, body.ToString()));
        return sections;
    }
    private static IEnumerable<TextBlock> Blocks(string text)
    {
        StringBuilder paragraph = new();
        TextBlock Normal(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.TrimEnd();
            bool heading = line.StartsWith('#'); bool list = line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal);
            if (line.Length == 0 || heading || list)
            {
                if (paragraph.Length > 0) { yield return Normal(paragraph.ToString()); paragraph.Clear(); }
                if (heading)
                {
                    int level = line.TakeWhile(c => c == '#').Count();
                    yield return new TextBlock { Text = line[level..].Trim(), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = level == 1 ? 28 : level == 2 ? 20 : 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 4) };
                }
                else if (list) yield return Normal("• " + line[2..]);
                continue;
            }
            if (paragraph.Length > 0) paragraph.Append(' ');
            paragraph.Append(line);
        }
        if (paragraph.Length > 0) yield return Normal(paragraph.ToString());
    }
}
