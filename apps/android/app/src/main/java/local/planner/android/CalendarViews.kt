package local.planner.android

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.TemporalAdjusters

internal enum class CalendarView(@get:StringRes val label: Int) {
    Month(R.string.calendar_view_month),
    Week(R.string.calendar_view_week),
    Day(R.string.calendar_view_day);

    fun dates(date: LocalDate, firstDay: DayOfWeek): CalendarDates = when (this) {
        Month -> CalendarDates(
            date.withDayOfMonth(1).with(TemporalAdjusters.previousOrSame(firstDay)),
            date.withDayOfMonth(1).plusMonths(1).with(TemporalAdjusters.nextOrSame(firstDay)),
        )
        Week -> date.with(TemporalAdjusters.previousOrSame(firstDay)).let { start ->
            CalendarDates(start, start.plusWeeks(1))
        }
        Day -> CalendarDates(date, date.plusDays(1))
    }

    fun move(date: LocalDate, by: Long): LocalDate = when (this) {
        Month -> date.plusMonths(by)
        Week -> date.plusWeeks(by)
        Day -> date.plusDays(by)
    }
}

internal data class CalendarDates(val start: LocalDate, val endExclusive: LocalDate) {
    val last: LocalDate get() = endExclusive.minusDays(1)
    val days: List<LocalDate> get() = generateSequence(start) { it.plusDays(1) }
        .takeWhile { it < endExclusive }.toList()
}

@Composable
internal fun CalendarPeriodNavigation(
    view: CalendarView, date: LocalDate, today: LocalDate, range: CalendarDates,
    select: (LocalDate) -> Unit, pickDate: () -> Unit,
) {
    val locale = LocalConfiguration.current.locales[0]
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val colors = MaterialTheme.colorScheme
    val currentDay = view == CalendarView.Day && date == today
    val todayLabel = stringResource(R.string.today)
    val title = when (view) {
        CalendarView.Month -> date.format(DateTimeFormatter.ofPattern("LLLL yyyy", locale))
            .replaceFirstChar { it.titlecase(locale) }
        CalendarView.Week -> stringResource(R.string.calendar_week_range, dateLabel(range.start), dateLabel(range.last))
        CalendarView.Day -> dateLabel(date, FormatStyle.FULL)
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { select(view.move(date, -1)) }) {
            Box(Modifier.rotate(if (rtl) 180f else 0f)) { Glyph(R.drawable.ic_back, stringResource(R.string.calendar_previous)) }
        }
        TextButton(onClick = pickDate, modifier = Modifier.weight(1f).semantics {
            if (currentDay) stateDescription = todayLabel
        }) {
            Text(
                title,
                Modifier.then(
                    if (currentDay) Modifier.background(colors.primary, RoundedCornerShape(12.dp)) else Modifier,
                ).padding(horizontal = 10.dp, vertical = 4.dp),
                color = if (currentDay) colors.onPrimary else colors.primary,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.titleSmall,
            )
        }
        IconButton(onClick = { select(view.move(date, 1)) }) {
            Box(Modifier.rotate(if (rtl) 0f else 180f)) { Glyph(R.drawable.ic_back, stringResource(R.string.calendar_next)) }
        }
    }
}

@Composable
internal fun CalendarDayGrid(
    range: CalendarDates, date: LocalDate, today: LocalDate, events: Map<LocalDate, List<PhoneEvent>>,
    showMonth: Boolean, select: (LocalDate) -> Unit, modifier: Modifier = Modifier,
) {
    val days = range.days
    val locale = LocalConfiguration.current.locales[0]
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            days.take(7).forEach { day ->
                Text(
                    day.dayOfWeek.getDisplayName(TextStyle.SHORT_STANDALONE, locale),
                    Modifier.weight(1f).padding(top = 2.dp, bottom = 4.dp),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
        days.chunked(7).forEach { week ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                week.forEach { day ->
                    CalendarDayCell(
                        day, selected = day == date, today = day == today,
                        muted = showMonth && day.month != date.month,
                        hasEvents = events[day]?.isNotEmpty() == true,
                        select = { select(day) }, modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun CalendarDayCell(
    day: LocalDate, selected: Boolean, today: Boolean, muted: Boolean, hasEvents: Boolean,
    select: () -> Unit, modifier: Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val label = dateLabel(day, FormatStyle.FULL)
    val description = if (hasEvents) stringResource(R.string.calendar_date_with_events, label) else label
    val todayLabel = stringResource(R.string.today)
    val textColor = when {
        today -> colors.onPrimary
        selected -> colors.onPrimaryContainer
        muted -> colors.onSurfaceVariant
        else -> colors.onSurface
    }
    Box(
        modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(12.dp)).then(
            if (selected) Modifier.background(colors.primaryContainer) else Modifier,
        ).selectable(selected, onClick = select).semantics {
            contentDescription = description
            if (today) stateDescription = todayLabel
        },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Box(
                Modifier.size(28.dp).then(
                    if (today) Modifier.background(colors.primary, CircleShape) else Modifier,
                ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    day.dayOfMonth.toString(), Modifier.clearAndSetSemantics {},
                    color = textColor, fontWeight = if (selected || today) FontWeight.SemiBold else null,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            Box(Modifier.size(4.dp).then(
                if (hasEvents) Modifier.background(if (selected) colors.onPrimaryContainer else colors.primary, CircleShape)
                else Modifier,
            ))
        }
    }
}
