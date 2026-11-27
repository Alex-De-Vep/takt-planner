package local.planner.android

internal class StaleNoteProposal : IllegalStateException()

internal fun StoredNote.chatContext(workspace: String): NoteChatContext {
    val text = document.text.replace("\uFFFC", "")
    return NoteChatContext(
        document.title.take(500), text.take(12_000), workspace, document.id, digest,
        editable = document.deletedAt == null && document.document.isEmpty() && text.length <= 12_000,
        truncated = text.length > 12_000,
    )
}

internal fun StoredNote.withChatText(proposal: ChatNoteProposal): NoteDocument {
    if (document.id != proposal.note.noteId || digest != proposal.note.digest || document.deletedAt != null) {
        throw StaleNoteProposal()
    }
    require(document.document.isEmpty() && proposal.note.editable && !proposal.note.truncated)
    val title = proposal.title
    require(title == null || title.isNotBlank() && title.length <= 500 && title.none(Char::isISOControl))
    val previous = document.copy(title = title ?: document.title)
    val body = proposal.body ?: return previous.copy(updatedAt = noteTime())
    require(body.isNotBlank() && body.length <= 16_000 && '\u0000' !in body && '\uFFFC' !in body)
    val images = previous.richText?.spans.orEmpty().filter { it.image != null }
    val text = body + "\n\uFFFC".repeat(images.size)
    val spans = images.mapIndexed { index, image ->
        val position = body.length + index * 2 + 1
        image.copy(start = position, end = position + 1)
    }
    val richText = if (previous.richText != null) SharedNoteText(spans = spans) else null
    richText?.validate(text)
    return previous.copy(text = text, richText = richText, updatedAt = noteTime())
}
