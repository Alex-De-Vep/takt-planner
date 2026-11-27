using System.Text;

namespace Takt.Core.Notes;

public static class NoteText
{
    // RichEdit uses one CR per paragraph. Keep a map so CRLF in a source note
    // does not shift formatting ranges or split supplementary Unicode characters.
    public static (string Text, SharedNoteText RichText) NormalizeNewlines(string text, SharedNoteText rich)
    {
        if (rich is null) throw new InvalidDataException("Shared note format version 1 is required.");
        rich.Validate(text); int[] map = new int[text.Length + 1]; StringBuilder result = new();
        for (int i = 0; i < text.Length; ++i)
        {
            map[i] = result.Length;
            if (text[i] == '\r')
            {
                result.Append('\n');
                if (i + 1 < text.Length && text[i + 1] == '\n') map[++i] = result.Length;
            }
            else result.Append(text[i]);
        }
        map[text.Length] = result.Length;
        var spans = rich.Spans.Select(s => s with { Start = map[s.Start], End = map[s.End] }).Where(s => s.End > s.Start).ToList();
        var value = new SharedNoteText(1, spans); value.Validate(result.ToString()); return (result.ToString(), value);
    }
    // Accept only actual PNG pict groups; never infer bytes by deleting unknown
    // RTF syntax. If the native editor cannot export a picture portably, saving
    // fails with the draft intact instead of silently losing the image.
    public static List<byte[]> RtfPngImages(string rtf)
    {
        List<byte[]> images = []; int depth = 0, pictureDepth = -1; bool png = false; StringBuilder hex = new();
        for (int i = 0; i < rtf.Length; ++i)
        {
            char c = rtf[i];
            if (c == '{') { ++depth; continue; }
            if (c == '}')
            {
                if (depth == pictureDepth)
                {
                    if (!png || hex.Length % 2 != 0) throw new InvalidDataException("Paste this image using Insert image or Paste image.");
                    var bytes = Convert.FromHexString(hex.ToString()); SharedNoteText.ValidatePng(bytes); images.Add(bytes);
                    pictureDepth = -1; png = false; hex.Clear();
                }
                if (--depth < 0) throw new InvalidDataException("Invalid rich text."); continue;
            }
            if (c == '\\')
            {
                if (++i >= rtf.Length) throw new InvalidDataException("Invalid rich text.");
                if (!char.IsAsciiLetter(rtf[i])) { if (rtf[i] == '\'') i += 2; continue; }
                int start = i; while (i < rtf.Length && char.IsAsciiLetter(rtf[i])) ++i;
                string word = rtf[start..i]; bool negative = i < rtf.Length && rtf[i] == '-'; if (negative) ++i;
                int digits = i; while (i < rtf.Length && char.IsAsciiDigit(rtf[i])) ++i;
                if (word == "bin") throw new InvalidDataException("Binary RTF images must be inserted using Insert image.");
                if (word == "pict") { if (pictureDepth >= 0) throw new InvalidDataException("Nested RTF images are unsupported."); pictureDepth = depth; }
                if (word == "pngblip" && depth == pictureDepth) png = true;
                if (i >= rtf.Length || rtf[i] != ' ') --i;
                continue;
            }
            if (depth == pictureDepth && !char.IsWhiteSpace(c))
            {
                if (!char.IsAsciiHexDigit(c) || hex.Length >= SharedNoteText.ImageLimit * 2) throw new InvalidDataException("Invalid or oversized embedded PNG.");
                hex.Append(c);
            }
        }
        if (depth != 0 || pictureDepth >= 0) throw new InvalidDataException("Unclosed rich text group.");
        return images;
    }
}
