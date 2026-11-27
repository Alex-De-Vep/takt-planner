package local.planner.android

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

internal enum class CreationAction(val label: Int, val icon: Int, val accent: WorkspaceAccent, val requiresNotes: Boolean = false) {
    Task(R.string.create_task, R.drawable.ic_list, WorkspaceAccent.Tasks),
    Note(R.string.create_note, R.drawable.ic_note, WorkspaceAccent.Notes, requiresNotes = true),
    Recording(R.string.create_recording, R.drawable.ic_waveform, WorkspaceAccent.Notes, requiresNotes = true),
    Event(R.string.create_event, R.drawable.ic_calendar, WorkspaceAccent.Events),
}

@Composable
internal fun CreationMenu(
    expanded: Boolean, onExpanded: (Boolean) -> Unit, notesReady: Boolean, accent: WorkspaceAccent,
    bottomInset: Dp, modifier: Modifier = Modifier, create: (CreationAction) -> Unit,
) {
    val scrimAlpha by animateFloatAsState(if (expanded) 0.52f else 0f, tween(180), label = "Create menu scrim")
    val rotation by animateFloatAsState(if (expanded) 45f else 0f, tween(200), label = "Create menu icon")
    BackHandler(expanded) { onExpanded(false) }
    Box(modifier) {
        if (expanded || scrimAlpha > 0f) {
            val close = stringResource(R.string.close)
            Box(
                Modifier.matchParentSize().background(Color.Black.copy(alpha = scrimAlpha))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null, role = Role.Button,
                    ) { onExpanded(false) }
                    .semantics { contentDescription = close },
            )
        }
        Column(
            Modifier.align(Alignment.BottomEnd)
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Top))
                .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = bottomInset + 16.dp),
            horizontalAlignment = Alignment.End,
        ) {
            AnimatedVisibility(
                visible = expanded,
                modifier = Modifier.weight(1f, fill = false),
                enter = fadeIn(tween(180)) + slideInVertically(tween(220)) { it / 5 },
                exit = fadeOut(tween(140)) + slideOutVertically(tween(180)) { it / 5 },
            ) {
                Column(
                    Modifier.verticalScroll(rememberScrollState(), reverseScrolling = true).padding(bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    horizontalAlignment = Alignment.End,
                ) {
                    CreationAction.entries.asReversed().forEach { action ->
                        val colors = action.accent.colors()
                        FilledTonalButton(
                            onClick = { create(action) },
                            enabled = expanded && (!action.requiresNotes || notesReady),
                            colors = ButtonDefaults.filledTonalButtonColors(
                                containerColor = if (action.accent == WorkspaceAccent.Notes) NoteActionColor else colors.primaryContainer,
                                contentColor = if (action.accent == WorkspaceAccent.Notes) OnNoteActionColor else colors.onPrimaryContainer,
                            ),
                        ) {
                            Glyph(action.icon, tint = LocalContentColor.current, size = 20.dp)
                            Text(stringResource(action.label), Modifier.padding(start = 10.dp))
                        }
                    }
                }
            }
            val colors = accent.colors()
            FloatingActionButton(
                onClick = { onExpanded(!expanded) },
                containerColor = if (accent == WorkspaceAccent.Notes) NoteActionColor else colors.primaryContainer,
                contentColor = if (accent == WorkspaceAccent.Notes) OnNoteActionColor else colors.onPrimaryContainer,
            ) {
                Box(Modifier.rotate(rotation)) {
                    Glyph(R.drawable.ic_add, stringResource(if (expanded) R.string.close else R.string.create_menu),
                        tint = LocalContentColor.current, size = 32.dp)
                }
            }
        }
    }
}
