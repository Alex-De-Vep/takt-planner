using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text;
using Takt.Core.Notes;
using global::Windows.Storage.Streams;
using global::Windows.Graphics.Imaging;

namespace Takt.Windows.Services;

// The editing surface is a native RichEditBox. Only the shared, supported styles
// enter the shared version-1 wire document.
public sealed class SharedNoteEditor(RichEditBox box)
{
    private readonly Dictionary<string, byte[]> images = [];
    private const string ImagePrefix = "Takt image ";
    public async Task LoadAsync(NoteDocument note)
    {
        images.Clear();
        NoteCodec.Validate(note);
        var defaults = box.Document.GetDefaultCharacterFormat();
        defaults.Name = "Segoe UI Variable"; defaults.Size = 16; defaults.Bold = FormatEffect.Off; defaults.Italic = FormatEffect.Off; defaults.Underline = UnderlineType.None;
        box.Document.SetDefaultCharacterFormat(defaults);
        var normalized = NoteText.NormalizeNewlines(note.Text, note.RichText!);
        string text = normalized.Item1; var rich = normalized.Item2;
        box.Document.SetText(TextSetOptions.None, text.Replace('\n', '\r'));
        var whole = box.Document.GetRange(0, text.Length);
        whole.ParagraphFormat.ListType = MarkerType.None;
        whole.CharacterFormat.Name = "Segoe UI Variable"; whole.CharacterFormat.Size = 16;
        whole.CharacterFormat.Bold = FormatEffect.Off; whole.CharacterFormat.Italic = FormatEffect.Off; whole.CharacterFormat.Underline = UnderlineType.None;
        foreach (var span in rich.Spans.OrderByDescending(s => s.Start))
        {
            var range = box.Document.GetRange(span.Start, span.End);
            range.CharacterFormat.Bold = span.Bold == true ? FormatEffect.On : FormatEffect.Off;
            range.CharacterFormat.Italic = span.Italic == true ? FormatEffect.On : FormatEffect.Off;
            range.CharacterFormat.Underline = span.Underline == true ? UnderlineType.Single : UnderlineType.None;
            range.CharacterFormat.Size = span.Size ?? 16;
            if (span.Image is { } image) await InsertImageAsync(Convert.FromBase64String(image), span.Start, span.End);
        }
        // Setting a native hyperlink inserts hidden field instructions. Apply in
        // reverse order after ranges/images, so earlier UTF-16 offsets stay valid.
        foreach (var span in rich.Spans.Where(s => s.Link is not null).OrderByDescending(s => s.Start))
            box.Document.GetRange(span.Start, span.End).Link = "\"" + span.Link + "\"";
        box.Document.Selection.SetRange(0, 0);
        // Undo must never restore the previous note into this note's identity.
        box.Document.ClearUndoRedoHistory();
    }
    public (string Text, SharedNoteText RichText) Capture()
    {
        box.Document.GetText(TextGetOptions.AllowFinalEop, out string native);
        if (!native.EndsWith('\r')) throw new InvalidDataException("The editor could not identify its final paragraph marker.");
        int end = native.Length - 1, imageOrdinal = 0; List<byte[]>? exportedImages = null;
        StringBuilder text = new(); List<NoteSpan> spans = [];
        for (int position = 0; position < end;)
        {
            int length = char.IsHighSurrogate(native[position]) && position + 1 < end && char.IsLowSurrogate(native[position + 1]) ? 2 : 1;
            var range = box.Document.GetRange(position, position + length); position += length;
            if (range.ParagraphFormat.ListType is not (MarkerType.None or MarkerType.Undefined)) throw new InvalidDataException("Paste list markers as plain text before saving this note.");
            if (range.CharacterFormat.Hidden == FormatEffect.On) continue;
            range.GetText(TextGetOptions.NoHidden, out string visible);
            visible = visible.Replace("\r", "\n").Replace("\u0013", "").Replace("\u0014", "").Replace("\u0015", "");
            if (visible.Length == 0) continue;
            string? image = null;
            if (visible == "\uFFFC")
            {
                range.GetText(TextGetOptions.UseObjectText, out string alt);
                byte[] data;
                if (alt.StartsWith(ImagePrefix, StringComparison.Ordinal) && images.TryGetValue(alt[ImagePrefix.Length..], out var known)) data = known;
                else
                {
                    if (exportedImages is null)
                    {
                        box.Document.GetText(TextGetOptions.FormatRtf, out string rtf); exportedImages = NoteText.RtfPngImages(rtf);
                        if (exportedImages.Count != native.Count(c => c == '\uFFFC')) throw new InvalidDataException("This pasted image cannot be saved safely. Undo the paste and use Insert image.");
                    }
                    data = exportedImages[imageOrdinal];
                }
                SharedNoteText.ValidatePng(data); image = Convert.ToBase64String(data); ++imageOrdinal;
            }
            var format = range.CharacterFormat; string? link = range.Link?.Trim('\uFDDF', '\"');
            if (link?.Length == 0) link = null;
            if (link is not null && !SharedNoteText.ValidLink(link)) link = null;
            int start = text.Length; text.Append(visible);
            int size = (int)Math.Round(format.Size);
            var span = new NoteSpan(start, text.Length, format.Bold == FormatEffect.On ? true : null,
                format.Italic == FormatEffect.On ? true : null, format.Underline != UnderlineType.None ? true : null,
                size is >= 8 and <= 72 && size != 16 ? size : null, link, image);
            if (!span.Styled) continue;
            if (span.Image is null && spans.LastOrDefault() is { Image: null } previous && previous.End == start &&
                (previous with { Start = span.Start, End = span.End }) == span)
                spans[^1] = previous with { End = span.End };
            else spans.Add(span);
        }
        var rich = new SharedNoteText(1, spans); rich.Validate(text.ToString()); return (text.ToString(), rich);
    }
    public void PasteText(string text, bool rtf, ITextRange target)
    {
        box.Document.GetText(TextGetOptions.AllowFinalEop, out string before);
        int start = target.StartPosition, replaced = target.EndPosition - start;
        Exception? failure = null;
        box.Document.BeginUndoGroup();
        try
        {
            target.SetText(rtf ? TextSetOptions.FormatRtf : TextSetOptions.None, rtf ? text : text.Replace("\r\n", "\r").Replace('\n', '\r'));
            box.Document.GetText(TextGetOptions.AllowFinalEop, out string after);
            int end = start + after.Length - before.Length + replaced;
            var inserted = box.Document.GetRange(start, end);
            inserted.CharacterFormat.Name = "Segoe UI Variable"; inserted.CharacterFormat.Size = 16;
            // Materialize native list markers as text: shared notes use literal
            // bullets/checkmarks and UTF-16 spans, never RTF paragraph metadata.
            List<ITextRange> paragraphs = [];
            for (int at = start; at < end;)
            {
                var paragraph = box.Document.GetRange(at, at); paragraph.Expand(TextRangeUnit.Paragraph);
                if (paragraph.ParagraphFormat.ListType is not (MarkerType.None or MarkerType.Undefined)) paragraphs.Add(paragraph.GetClone());
                if (paragraph.EndPosition <= at) break;
                at = paragraph.EndPosition;
            }
            foreach (var paragraph in paragraphs.OrderByDescending(p => p.StartPosition))
            {
                paragraph.GetText(TextGetOptions.NoHidden | TextGetOptions.IncludeNumbering, out string numbered);
                paragraph.GetText(TextGetOptions.NoHidden, out string plain);
                if (plain.Length == 0 || !numbered.EndsWith(plain, StringComparison.Ordinal)) throw new InvalidDataException("The pasted list could not be represented safely.");
                string marker = numbered[..(numbered.Length - plain.Length)].Replace('\t', ' ');
                paragraph.ParagraphFormat.ListType = MarkerType.None;
                box.Document.GetRange(paragraph.StartPosition, paragraph.StartPosition).SetText(TextSetOptions.None, marker);
            }
            _ = Capture();
        }
        catch (Exception error) { failure = error; }
        finally { box.Document.EndUndoGroup(); }
        if (failure is not null)
        {
            box.Document.Undo();
            throw new InvalidDataException("This clipboard content cannot be saved in a shared note. The paste was undone; use plain text or Insert image.", failure);
        }
    }
    public void Format(string style)
    {
        box.Focus(FocusState.Programmatic); var selected = box.Document.Selection;
        switch (style)
        {
            case "bold": selected.CharacterFormat.Bold = FormatEffect.Toggle; break;
            case "italic": selected.CharacterFormat.Italic = FormatEffect.Toggle; break;
            case "underline": selected.CharacterFormat.Underline = selected.CharacterFormat.Underline == UnderlineType.Single ? UnderlineType.None : UnderlineType.Single; break;
            case "heading": selected.CharacterFormat.Size = 24; selected.CharacterFormat.Bold = FormatEffect.On; break;
            case "body": selected.CharacterFormat.Size = 16; selected.CharacterFormat.Bold = FormatEffect.Off; break;
            case "bullet": selected.SetText(TextSetOptions.None, "• "); break;
            case "number": selected.SetText(TextSetOptions.None, "1. "); break;
            case "check": selected.SetText(TextSetOptions.None, "☐ "); break;
        }
    }
    public void Link(string address)
    {
        if (!SharedNoteText.ValidLink(address)) throw new ArgumentException("Use an http, https or mailto link.");
        box.Focus(FocusState.Programmatic); var selected = box.Document.Selection;
        if (selected.StartPosition == selected.EndPosition)
        {
            int start = selected.StartPosition; selected.SetText(TextSetOptions.None, address); selected.SetRange(start, start + address.Length);
        }
        selected.Link = "\"" + address + "\"";
    }
    public async Task InsertImageAsync(byte[] png, int? start = null, int? end = null, ITextRange? target = null)
    {
        // Clone before the first await: later caret movement must not relocate the image.
        var range = start is { } at ? box.Document.GetRange(at, end ?? at) : target ?? box.Document.Selection.GetClone();
        var (width, height) = SharedNoteText.ValidatePng(png); string digest = NoteCodec.Digest(png); images[digest] = png;
        using var stream = new InMemoryRandomAccessStream(); using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png); await writer.StoreAsync(); }
        stream.Seek(0);
        double scale = Math.Min(1, 560d / width);
        range.InsertImage(Math.Max(1, (int)(width * scale)), Math.Max(1, (int)(height * scale)), 0, VerticalCharacterAlignment.Baseline, ImagePrefix + digest, stream);
    }
    public static async Task<byte[]> PngAsync(IRandomAccessStream input)
    {
        var decoder = await BitmapDecoder.CreateAsync(input);
        if (decoder.PixelWidth > 12000 || decoder.PixelHeight > 12000) throw new InvalidDataException("This image is too large to decode safely.");
        if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 25000000) throw new InvalidDataException("Choose an image of at most 25 megapixels.");
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        double scale = Math.Min(1, 2500d / Math.Max(bitmap.PixelWidth, bitmap.PixelHeight));
        using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetSoftwareBitmap(bitmap);
        encoder.BitmapTransform.ScaledWidth = Math.Max(1, (uint)(bitmap.PixelWidth * scale));
        encoder.BitmapTransform.ScaledHeight = Math.Max(1, (uint)(bitmap.PixelHeight * scale));
        await encoder.FlushAsync();
        if (output.Size > SharedNoteText.ImageLimit) throw new InvalidDataException("The PNG exceeds 2 MiB. Choose a smaller image.");
        output.Seek(0); using var reader = new DataReader(output.GetInputStreamAt(0)); await reader.LoadAsync((uint)output.Size);
        byte[] bytes = new byte[(int)output.Size]; reader.ReadBytes(bytes); SharedNoteText.ValidatePng(bytes); return bytes;
    }
}
