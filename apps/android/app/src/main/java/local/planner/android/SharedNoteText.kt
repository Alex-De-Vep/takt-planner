package local.planner.android

import java.net.URI
import java.util.Base64

internal const val NOTE_FORMAT_VERSION = 1
internal const val NOTE_IMAGE_LIMIT = 2 * 1024 * 1024

internal data class SharedNoteText(
    val version: Int = NOTE_FORMAT_VERSION,
    val spans: List<NoteSpan> = emptyList(),
) {
    fun validate(text: String) {
        require(version == NOTE_FORMAT_VERSION && spans.size <= 4096)
        var previousEnd = 0
        val images = mutableSetOf<Int>()
        fun boundary(index: Int) = index == text.length || !text[index].isLowSurrogate()
        for (span in spans) {
            require(span.start >= previousEnd && span.end > span.start && span.end <= text.length &&
                boundary(span.start) && boundary(span.end))
            require(span.size == null || span.size in 8..72)
            require(span.link == null || validNoteLink(span.link))
            if (span.image != null) {
                require(span.end - span.start == 1 && text[span.start] == '\uFFFC')
                require(span.image.length <= (NOTE_IMAGE_LIMIT + 2) / 3 * 4)
                val bytes = Base64.getDecoder().decode(span.image)
                require(bytes.size <= NOTE_IMAGE_LIMIT && validNotePng(bytes))
                images.add(span.start)
            }
            previousEnd = span.end
        }
        require(text.indices.none { text[it] == '\uFFFC' && it !in images })
    }
}

internal data class NoteSpan(
    val start: Int,
    val end: Int,
    val bold: Boolean? = null,
    val italic: Boolean? = null,
    val underline: Boolean? = null,
    val size: Int? = null,
    val link: String? = null,
    val image: String? = null,
) {
    val styled get() = bold == true || italic == true || underline == true || size != null || link != null || image != null
}

internal fun validNoteLink(link: String): Boolean {
    if (link.toByteArray().size > 2048) return false
    val uri = runCatching { URI(link) }.getOrNull() ?: return false
    return when (uri.scheme?.lowercase()) {
        "http", "https" -> !uri.host.isNullOrBlank()
        "mailto" -> uri.rawSchemeSpecificPart.isNotBlank()
        else -> false
    }
}

private fun validNotePng(bytes: ByteArray): Boolean {
    val header = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
    if (bytes.size < 24 || !header.contentEquals(bytes.copyOfRange(0, 8)) ||
        !byteArrayOf(73, 72, 68, 82).contentEquals(bytes.copyOfRange(12, 16))) return false
    fun dimension(at: Int) = (at until at + 4).fold(0L) { value, i -> (value shl 8) or (bytes[i].toLong() and 255) }
    return dimension(16) in 1L..2500 && dimension(20) in 1L..2500
}
