package local.planner.android

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

internal const val TaskPrimaryLight = 0xFF7650B5L
internal const val TaskPrimaryDark = 0xFFB79BEAL
internal const val TaskOnPrimaryDark = 0xFF2D174FL
internal const val NotePrimaryDark = 0xFF70BFA2L
internal const val EventPrimaryLight = 0xFF456FAFL
internal const val EventPrimaryDark = 0xFF8EB9F2L
internal val NoteActionColor = Color(0xFF7BC8AB)
internal val OnNoteActionColor = Color(0xFF173B2C)
private const val AssistantBlue = 0xFF2E58FFL

internal enum class WorkspaceAccent {
    Tasks, Notes, Events, Chat, Settings;

    @Composable
    fun colors(): ColorScheme {
        val base = MaterialTheme.colorScheme
        val dark = isSystemInDarkTheme()
        return remember(this, base, dark) {
            when (this) {
                Tasks -> base
                Notes -> if (dark) {
                    base.withAccent(NotePrimaryDark, 0xFF102C21, 0xFF26483A, 0xFFD2F3E5)
                } else {
                    base.withAccent(0xFF326B55, 0xFFFFFFFF, 0xFFDDF2E9, 0xFF173B2C)
                }
                Events -> if (dark) {
                    base.withAccent(EventPrimaryDark, 0xFF151B2D, 0xFF284264, 0xFFDBE9FC)
                } else {
                    base.withAccent(EventPrimaryLight, 0xFFFFFFFF, 0xFFDDEAFE, 0xFF152B47)
                }
                Chat -> if (dark) {
                    base.withAccent(AssistantBlue, 0xFFFFFFFF, 0xFF282C37, 0xFFE1E7FA)
                } else {
                    base.withAccent(AssistantBlue, 0xFFFFFFFF, 0xFFEDF1F8, 0xFF162548)
                }
                Settings -> if (dark) {
                    base.withAccent(0xFFA7B1BF, 0xFF202733, 0xFF323740, 0xFFE4E8EF)
                } else {
                    base.withAccent(0xFF59616D, 0xFFFFFFFF, 0xFFE9ECF1, 0xFF252A34)
                }
            }
        }
    }
}

private fun ColorScheme.withAccent(primary: Long, onPrimary: Long, container: Long, onContainer: Long): ColorScheme =
    copy(
        primary = Color(primary), onPrimary = Color(onPrimary),
        primaryContainer = Color(container), onPrimaryContainer = Color(onContainer),
        secondaryContainer = Color(container), onSecondaryContainer = Color(onContainer),
        surfaceTint = Color(primary),
    )

private val AssistantGradientColors = listOf(
    Color(AssistantBlue), Color(0xFF584FFF), Color(0xFF7446FC), Color(0xFF8C3DF4),
    Color(0xFFA134E8), Color(0xFFB42BD9), Color(0xFFC51FC6), Color(0xFFD410B1),
    Color(0xFFE0009A), Color(0xFFEA0080), Color(0xFFF20066), Color(0xFFF90046), Color(0xFFFF0000),
)

internal val AssistantActionGradient = Brush.linearGradient(AssistantGradientColors)
internal val AssistantReplyGradient = Brush.linearGradient(AssistantGradientColors.map { it.copy(alpha = 0.13f) })
