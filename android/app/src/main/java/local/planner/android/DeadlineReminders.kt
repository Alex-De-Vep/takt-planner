package local.planner.android

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.time.LocalTime
import kotlin.concurrent.thread

internal object DeadlineReminders {
    private const val CHANNEL = "task_deadlines"
    private const val ALARM = "local.planner.android.DEADLINE"
    private const val ENABLED = "enabled"
    private const val WORKSPACE = "workspace"
    private const val TIME = "time"

    private fun preferences(context: Context) = context.getSharedPreferences("deadline_reminders", Context.MODE_PRIVATE)
    fun enabled(context: Context) = preferences(context).getBoolean(ENABLED, false)
    fun permissionGranted(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    @Synchronized
    fun setEnabled(context: Context, library: Library, enabled: Boolean) {
        preferences(context).edit().putBoolean(ENABLED, enabled).apply()
        update(context, library)
    }

    @Synchronized
    fun update(context: Context, library: Library, deliver: Boolean = false) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val notifications = context.getSystemService(NotificationManager::class.java)
        val intent = PendingIntent.getBroadcast(context, 0, Intent(context, DeadlineReceiver::class.java).setAction(ALARM),
            PendingIntent.FLAG_IMMUTABLE)
        val prefs = preferences(context)
        val scheduled = prefs.getLong(TIME, -1).takeIf { prefs.getString(WORKSPACE, null) == library.workspace }
        val now = System.currentTimeMillis()
        val dates = if (enabled(context) && permissionGranted(context) && notifications.areNotificationsEnabled()) {
            library.tasks.filterNot(Entity::completed).mapNotNull { task ->
                task.deadline?.let { task to it.reminderAt() }
            }
        } else emptyList()

        if (deliver && scheduled != null && scheduled <= now) {
            dates.filter { (_, time) -> time in maxOf(scheduled, now - 24 * 60 * 60 * 1000)..now }
                .forEach { (task, _) -> notify(context, notifications, task) }
        } else if (scheduled != null && scheduled <= now && dates.any { it.second == scheduled }) {
            // Android может ещё удерживать неточный сигнал. Оставляем его в очереди.
            return
        }

        val next = dates.asSequence().map { it.second }.filter { it > now }.minOrNull()
        if (next == null) {
            alarms.cancel(intent)
            prefs.edit().remove(WORKSPACE).remove(TIME).apply()
        } else {
            prefs.edit().putString(WORKSPACE, library.workspace).putLong(TIME, next).apply()
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, intent)
        }
    }

    fun isDeadline(intent: Intent) = intent.action == ALARM

    private fun notify(context: Context, manager: NotificationManager, task: Entity) {
        if (!permissionGranted(context)) return
        manager.createNotificationChannel(NotificationChannel(CHANNEL,
            context.getString(R.string.deadline_notifications), NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_calendar)
            .setContentTitle(context.getString(R.string.deadline))
            .setContentText(task.text("title").orEmpty().ifBlank { context.getString(R.string.untitled) })
            .setContentIntent(open).setAutoCancel(true).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        manager.notify(task.id, 1, notification)
    }
}

internal fun Deadline.reminderAt() = (instant ?: date.atTime(LocalTime.of(9, 0)).atZone(zone).toInstant()).toEpochMilli()

class DeadlineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        thread(name = "planner-reminders") {
            try {
                PlannerStore(context.applicationContext).use { store ->
                    store.load()
                    DeadlineReminders.update(context, store.library.value, deliver = DeadlineReminders.isDeadline(intent))
                }
            } finally {
                pending.finish()
            }
        }
    }
}
