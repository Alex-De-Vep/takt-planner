package local.planner.android

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.LocalPinnableContainer
import androidx.compose.ui.layout.PinnableContainer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

internal fun mergeFolderOrder(requested: List<String>, available: List<String>): List<String> {
    val allowed = available.toSet()
    return (requested.filter { it in allowed } + available).distinct()
}

internal fun List<String>.moveFolder(id: String, target: Int): List<String> {
    val from = indexOf(id)
    if (from < 0 || target !in indices || from == target) return this
    return toMutableList().apply { add(target, removeAt(from)) }
}

@Composable
internal fun FolderOrderEditor(
    folders: List<Entity>, save: (List<String>) -> Unit, rename: (String) -> Unit, delete: (String) -> Unit,
) {
    val ids = folders.map(Entity::id)
    val byId = folders.associateBy(Entity::id)
    val currentIds by rememberUpdatedState(ids)
    val commit by rememberUpdatedState(save)
    var dragged by remember { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf(emptyList<String>()) }
    var finger by remember { mutableFloatStateOf(0f) }
    val list = rememberLazyListState()
    var listCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val displayed = if (dragged == null) ids else mergeFolderOrder(draft, ids)
    val edge = with(LocalDensity.current) { 36.dp.toPx() }

    fun reorderAtFinger() {
        val id = dragged ?: return
        val visible = list.layoutInfo.visibleItemsInfo
        val target = visible.firstOrNull { finger >= it.offset && finger < it.offset + it.size } ?: return
        val current = visible.firstOrNull { it.key == id }
        if (current != null && target.key != id) {
            val middle = target.offset + target.size / 2f
            if (target.index > current.index && finger < middle || target.index < current.index && finger > middle) return
        }
        draft = mergeFolderOrder(draft, currentIds).moveFolder(id, target.index)
    }

    LaunchedEffect(dragged) {
        if (dragged == null) return@LaunchedEffect
        while (dragged != null) {
            val layout = list.layoutInfo
            val top = layout.viewportStartOffset + edge
            val bottom = layout.viewportEndOffset - edge
            val delta = when {
                finger < top -> ((finger - top) * 0.22f).coerceAtLeast(-edge / 2)
                finger > bottom -> ((finger - bottom) * 0.22f).coerceAtMost(edge / 2)
                else -> 0f
            }
            if (delta != 0f && list.scrollBy(delta) != 0f) reorderAtFinger()
            delay(16)
        }
    }

    LazyColumn(state = list, modifier = Modifier.fillMaxWidth().heightIn(max = 400.dp)
        .onGloballyPositioned { listCoordinates = it }) {
        itemsIndexed(displayed, key = { _, id -> id }) { index, id ->
            val folder = byId.getValue(id)
            val name = folder.text("name").orEmpty()
            val label = stringResource(R.string.folder_drag_handle, name)
            val up = stringResource(R.string.folder_move_up)
            val down = stringResource(R.string.folder_move_down)
            val pinnable = LocalPinnableContainer.current
            var pin by remember { mutableStateOf<PinnableContainer.PinnedHandle?>(null) }
            var handleCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
            DisposableEffect(Unit) { onDispose { pin?.release() } }
            Row(
                Modifier.fillMaxWidth().background(
                    if (id == dragged) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
                ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(48.dp).onGloballyPositioned { handleCoordinates = it }.semantics {
                        contentDescription = label
                        customActions = buildList {
                            if (index > 0) add(CustomAccessibilityAction(up) {
                                commit(currentIds.moveFolder(id, index - 1)); true
                            })
                            if (index < displayed.lastIndex) add(CustomAccessibilityAction(down) {
                                commit(currentIds.moveFolder(id, index + 1)); true
                            })
                        }
                    }.pointerInput(id) {
                        detectDragGestures(
                            onDragStart = {
                                list.layoutInfo.visibleItemsInfo.firstOrNull { item -> item.key == id }?.let { item ->
                                    pin = pinnable?.pin()
                                    draft = currentIds
                                    finger = item.offset + item.size / 2f
                                    dragged = id
                                }
                            },
                            onDragEnd = {
                                if (dragged == id) commit(mergeFolderOrder(draft, currentIds))
                                dragged = null
                                pin?.release()
                                pin = null
                            },
                            onDragCancel = {
                                dragged = null
                                pin?.release()
                                pin = null
                            },
                        ) { change, _ ->
                            if (dragged == id) {
                                change.consume()
                                val viewport = listCoordinates?.takeIf(LayoutCoordinates::isAttached)
                                val handle = handleCoordinates?.takeIf(LayoutCoordinates::isAttached)
                                if (viewport != null && handle != null) {
                                    finger = viewport.localPositionOf(handle, change.position).y
                                    reorderAtFinger()
                                }
                            }
                        }
                    },
                    contentAlignment = Alignment.Center,
                ) { Glyph(R.drawable.ic_drag_handle, tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                Text(name, Modifier.weight(1f).padding(horizontal = 2.dp), maxLines = 2, overflow = TextOverflow.Ellipsis)
                ActionIcon(R.drawable.ic_edit, R.string.rename_folder) { rename(id) }
                ActionIcon(R.drawable.ic_delete, R.string.delete_folder) { delete(id) }
            }
        }
    }
}
