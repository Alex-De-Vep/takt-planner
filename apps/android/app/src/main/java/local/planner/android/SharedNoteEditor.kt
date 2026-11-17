package local.planner.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.text.Editable
import android.text.InputType
import android.text.Spannable
import android.text.SpannableString
import android.text.TextWatcher
import android.text.style.ImageSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.URLSpan
import android.text.style.UnderlineSpan
import android.util.TypedValue
import android.view.Gravity
import android.widget.EditText
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayOutputStream
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val NOTE_BODY_SIZE = 16
private const val SPAN_FLAGS = Spannable.SPAN_EXCLUSIVE_EXCLUSIVE

@Composable
internal fun SharedNoteEditor(draft: NoteDraft, editable: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var editor by remember { mutableStateOf<EditText?>(null) }
    var addLink by remember { mutableStateOf(false) }
    var imageError by remember { mutableStateOf(false) }
    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            try {
                val png = withContext(Dispatchers.IO) { readNoteImage(context, uri) }
                editor?.takeIf { it.isEnabled }?.insertImage(png)
                imageError = false
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                imageError = true
            }
        }
    }
    val hint = stringResource(R.string.note_text)
    val bodyColor = MaterialTheme.colorScheme.onSurface.toArgb()
    val hintColor = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
    val accent = MaterialTheme.colorScheme.primary.toArgb()

    Column {
        if (draft.original?.document?.deletedAt == null) {
            NoteFormatBar(
                editor = editor,
                enabled = editable && editor != null,
                addLink = { addLink = true },
                addImage = { imagePicker.launch("image/*") },
            )
        }
        AndroidView(
            modifier = Modifier.fillMaxWidth(),
            factory = { ctx ->
                EditText(ctx).apply {
                    background = null
                    val pad = (16 * resources.displayMetrics.density).toInt()
                    setPadding(pad, pad / 2, pad, pad / 2)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, NOTE_BODY_SIZE.toFloat())
                    gravity = Gravity.START or Gravity.TOP
                    minLines = 4
                    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                        InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                    linksClickable = false
                    setText(renderNote(ctx, draft.text, draft.richText), android.widget.TextView.BufferType.EDITABLE)
                    addTextChangedListener(object : TextWatcher {
                        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                        override fun afterTextChanged(s: Editable?) { publishNote(draft) }
                    })
                    // Formatting actions can add spans without triggering TextWatcher.
                    setTag(R.id.note_editor_change, { publishNote(draft) } as () -> Unit)
                    editor = this
                }
            },
            update = { view ->
                view.hint = hint
                view.contentDescription = hint
                view.setTextColor(bodyColor)
                view.setHintTextColor(hintColor)
                view.setLinkTextColor(accent)
                view.isEnabled = editable
                if (view.text.toString() != draft.text) {
                    val cursor = view.selectionEnd.coerceIn(0, draft.text.length)
                    view.setText(renderNote(context, draft.text, draft.richText), android.widget.TextView.BufferType.EDITABLE)
                    view.setSelection(cursor)
                }
            },
        )
        if (imageError) Text(stringResource(R.string.note_image_error), color = MaterialTheme.colorScheme.error)
    }
    if (addLink) {
        NameDialog(R.string.note_link, R.string.note_link, "https://", { addLink = false }) { url ->
            val link = url.trim()
            if (validNoteLink(link)) {
                editor?.applyLink(link)
                addLink = false
            }
        }
    }
}

@Composable
private fun NoteFormatBar(editor: EditText?, enabled: Boolean, addLink: () -> Unit, addImage: () -> Unit) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            NoteFormatButton("B", R.string.note_bold, enabled, TextStyle(fontWeight = FontWeight.Bold)) {
                editor?.toggleTypeface(Typeface.BOLD)
            }
            NoteFormatButton("I", R.string.note_italic, enabled, TextStyle(fontStyle = FontStyle.Italic)) {
                editor?.toggleTypeface(Typeface.ITALIC)
            }
            ActionIcon(R.drawable.ic_list, R.string.note_list, enabled = enabled) { editor?.prefixParagraph("• ") }
            NoteFormatButton("☐", R.string.note_checklist, enabled) { editor?.prefixParagraph("☐ ") }
            ActionIcon(R.drawable.ic_link, R.string.note_link, enabled = enabled, onClick = addLink)
            ActionIcon(R.drawable.ic_image, R.string.note_image, enabled = enabled, onClick = addImage)
            NoteFormatButton("H", R.string.note_heading, enabled, TextStyle(fontWeight = FontWeight.SemiBold)) {
                editor?.toggleRange({ it is RelativeSizeSpan }, { RelativeSizeSpan(1.5f) })
            }
            NoteFormatButton("U", R.string.note_underline, enabled, TextStyle(textDecoration = TextDecoration.Underline)) {
                editor?.toggleRange({ it is UnderlineSpan }, { UnderlineSpan() })
            }
            NoteFormatButton("1.", R.string.note_numbered_list, enabled) { editor?.prefixParagraph("1. ") }
        }
    }
}

@Composable
private fun NoteFormatButton(
    symbol: String, description: Int, enabled: Boolean, style: TextStyle = TextStyle.Default, onClick: () -> Unit,
) {
    val label = stringResource(description)
    IconButton(onClick, Modifier.semantics { contentDescription = label }, enabled = enabled) {
        Text(symbol, style = MaterialTheme.typography.titleMedium.merge(style))
    }
}

private fun EditText.toggleTypeface(style: Int) =
    toggleRange({ it is StyleSpan && it.style == style }, { StyleSpan(style) })

private class NoteImageSpan(context: Context, val png: String, bitmap: Bitmap) : ImageSpan(
    BitmapDrawable(context.resources, bitmap).apply {
        val maxWidth = (220 * context.resources.displayMetrics.density).toInt().coerceAtLeast(1)
        val width = bitmap.width.coerceAtMost(maxWidth)
        val height = (bitmap.height.toDouble() * width / bitmap.width).toInt().coerceAtLeast(1)
        setBounds(0, 0, width, height)
    },
)

private fun renderNote(context: Context, text: String, body: SharedNoteText?): SpannableString =
    SpannableString(text).apply {
        body?.spans?.forEach { span ->
            fun applyStyle(style: Any) = setSpan(style, span.start, span.end, SPAN_FLAGS)
            if (span.bold == true) applyStyle(StyleSpan(Typeface.BOLD))
            if (span.italic == true) applyStyle(StyleSpan(Typeface.ITALIC))
            if (span.underline == true) applyStyle(UnderlineSpan())
            span.size?.let { applyStyle(RelativeSizeSpan(it.toFloat() / NOTE_BODY_SIZE)) }
            span.link?.let { applyStyle(URLSpan(it)) }
            span.image?.let { png ->
                val bytes = Base64.getDecoder().decode(png)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { applyStyle(NoteImageSpan(context, png, it)) }
            }
        }
    }

private fun EditText.publishNote(draft: NoteDraft) {
    val content = text ?: return
    val spans = content.getSpans(0, content.length, Any::class.java).filter {
        (it is StyleSpan || it is UnderlineSpan || it is RelativeSizeSpan || it is URLSpan || it is NoteImageSpan) &&
            content.getSpanStart(it) < content.getSpanEnd(it)
    }
    val breaks = spans.flatMap { listOf(content.getSpanStart(it), content.getSpanEnd(it)) }.distinct().sorted()
    val styles = breaks.zipWithNext().mapNotNull { (start, end) ->
        val active = content.getSpans(start, end, Any::class.java)
        val font = active.filterIsInstance<StyleSpan>().fold(0) { flags, span -> flags or span.style }
        NoteSpan(
            start, end,
            bold = true.takeIf { font and Typeface.BOLD != 0 },
            italic = true.takeIf { font and Typeface.ITALIC != 0 },
            underline = true.takeIf { active.any { it is UnderlineSpan } },
            size = active.filterIsInstance<RelativeSizeSpan>().lastOrNull()?.sizeChange?.let {
                (it * NOTE_BODY_SIZE).toInt().coerceIn(8, 72)
            },
            link = active.filterIsInstance<URLSpan>().lastOrNull()?.url?.takeIf(::validNoteLink),
            image = active.filterIsInstance<NoteImageSpan>().firstOrNull()?.png?.takeIf {
                end - start == 1 && content[start] == '\uFFFC'
            },
        ).takeIf(NoteSpan::styled)
    }
    val images = styles.filter { it.image != null }.mapTo(hashSetOf(), NoteSpan::start)
    val raw = content.toString()
    val plain = if ('\uFFFC' in raw) buildString(raw.length) {
        raw.forEachIndexed { index, char -> append(if (char == '\uFFFC' && index !in images) '\uFFFD' else char) }
    } else raw
    draft.richText = if (styles.isEmpty() && draft.original?.document?.richText == null) null else SharedNoteText(spans = styles)
    draft.text = plain
}

private fun EditText.toggleRange(matches: (Any) -> Boolean, span: () -> Any) {
    val body = text ?: return
    val (start, end) = selectionForFormat(body)
    if (start == end) return
    val present = body.getSpans(start, end, Any::class.java).filter(matches)
    val remove = present.any { body.getSpanStart(it) <= start && body.getSpanEnd(it) >= end }
    present.forEach {
        val previousStart = body.getSpanStart(it)
        val previousEnd = body.getSpanEnd(it)
        body.removeSpan(it)
        if (previousStart < start) body.setSpan(it, previousStart, start, SPAN_FLAGS)
        if (previousEnd > end) body.setSpan(
            if (previousStart < start) copyFormatSpan(it) else it, end, previousEnd, SPAN_FLAGS,
        )
    }
    if (!remove) body.setSpan(span(), start, end, SPAN_FLAGS)
    change()
}

private fun copyFormatSpan(span: Any): Any = when (span) {
    is StyleSpan -> StyleSpan(span.style)
    is RelativeSizeSpan -> RelativeSizeSpan(span.sizeChange)
    is UnderlineSpan -> UnderlineSpan()
    else -> error("Unexpected note span")
}

private fun EditText.selectionForFormat(body: Editable): Pair<Int, Int> {
    val start = minOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    val end = maxOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    if (start != end) return start to end
    return paragraphStart(body, start) to body.indexOf('\n', start).takeIf { it >= 0 }.let { it ?: body.length }
}

private fun paragraphStart(text: CharSequence, cursor: Int) =
    if (cursor == 0) 0 else text.lastIndexOf('\n', cursor - 1) + 1

private fun EditText.prefixParagraph(prefix: String) {
    val body = text ?: return
    val start = paragraphStart(body, selectionStart.coerceIn(0, body.length))
    body.insert(start, prefix)
}

private fun EditText.applyLink(url: String) {
    val body = text ?: return
    val start = minOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    val end = maxOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    if (start == end) {
        body.insert(start, SpannableString(url).apply { setSpan(URLSpan(url), 0, length, SPAN_FLAGS) })
    } else {
        body.getSpans(start, end, URLSpan::class.java).forEach {
            val previousStart = body.getSpanStart(it)
            val previousEnd = body.getSpanEnd(it)
            body.removeSpan(it)
            if (previousStart < start) body.setSpan(URLSpan(it.url), previousStart, start, SPAN_FLAGS)
            if (previousEnd > end) body.setSpan(URLSpan(it.url), end, previousEnd, SPAN_FLAGS)
        }
        body.setSpan(URLSpan(url), start, end, SPAN_FLAGS)
        change()
    }
}

private fun EditText.insertImage(png: ByteArray) {
    val body = text ?: return
    val start = minOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    val end = maxOf(selectionStart, selectionEnd).coerceIn(0, body.length)
    val bitmap = requireNotNull(BitmapFactory.decodeByteArray(png, 0, png.size))
    val image = NoteImageSpan(context, Base64.getEncoder().encodeToString(png), bitmap)
    body.replace(start, end, SpannableString("\uFFFC").apply { setSpan(image, 0, 1, SPAN_FLAGS) })
}

private fun EditText.change() {
    @Suppress("UNCHECKED_CAST")
    (getTag(R.id.note_editor_change) as? (() -> Unit))?.invoke()
}

private fun readNoteImage(context: Context, uri: Uri): ByteArray {
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    require(bounds.outWidth in 1..30_000 && bounds.outHeight in 1..30_000)
    var sampleSize = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sampleSize > 1600) sampleSize *= 2
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
    var bitmap = requireNotNull(resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) })
    try {
        repeat(5) {
            val output = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            if (output.size() <= NOTE_IMAGE_LIMIT) return output.toByteArray()
            val smaller = Bitmap.createScaledBitmap(bitmap, (bitmap.width * .75).toInt().coerceAtLeast(1),
                (bitmap.height * .75).toInt().coerceAtLeast(1), true)
            if (smaller !== bitmap) bitmap.recycle()
            bitmap = smaller
        }
        error("Note image exceeds the limit")
    } finally {
        bitmap.recycle()
    }
}
