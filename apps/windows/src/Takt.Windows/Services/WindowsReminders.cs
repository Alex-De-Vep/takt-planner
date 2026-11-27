using CommunityToolkit.WinUI.Notifications;
using System.Security.Cryptography;
using System.Text;
using Takt.Core.Models;
using global::Windows.UI.Notifications;

namespace Takt.Windows.Services;

// Native scheduled notifications survive process exit. Refill the nearest 32 task reminders on
// edits, activation and the periodic refresh. Windows settings still control delivery.
public sealed class WindowsReminders
{
    private string? fingerprint;
    public static string Scope(string workspace) => "takt" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(LibraryDirectories.Active == LibraryDirectories.Root ? workspace : LibraryDirectories.Active + "|" + workspace)))[..12].ToLowerInvariant();
    public void ScheduleTest()
    {
        const string group = "test-notice";
        var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
        if (notifier.Setting != NotificationSetting.Enabled)
            throw new InvalidOperationException("Windows is blocking Takt notifications. Check Settings → System → Notifications.");

        foreach (var existing in notifier.GetScheduledToastNotifications().Where(item => item.Group == group))
            notifier.RemoveFromSchedule(existing);

        var content = new ToastContentBuilder()
            .AddArgument("notificationTest", "1")
            .AddText("Takt")
            .AddText("This is a test notification.")
            .GetToastContent().GetXml();
        var test = new ScheduledToastNotification(content, DateTimeOffset.Now.AddSeconds(5))
        {
            Id = "test",
            Tag = "test",
            Group = group
        };
        notifier.AddToSchedule(test);
    }

    public void Update(Library library, Preferences preferences)
    {
        string marker = Path.Combine(LibraryDirectories.Root, "scheduled-reminders-v1");
        if (!preferences.DeadlineReminders && !preferences.ReviewReminder && fingerprint is null && !File.Exists(marker)) return;
        var planned = new List<(string Id, string Title, DateTimeOffset Due)>();
        var now = DateTimeOffset.Now;
        if (preferences.DeadlineReminders)
            foreach (var task in library.Tasks.Where(t => !t.Completed && t.Deadline is not null))
            {
                var deadline = task.Deadline!;
                DateTimeOffset due;
                if (deadline.IncludesTime) due = DateTimeOffset.Parse(deadline.Instant!, System.Globalization.CultureInfo.InvariantCulture);
                else
                {
                    var local = deadline.LocalParts().Date.ToDateTime(new TimeOnly(preferences.DateOnlyHour, 0));
                    if (TimeZoneInfo.Local.IsInvalidTime(local)) local = local.AddHours(1);
                    due = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
                }
                if (due > now) planned.Add((task.Id, task.Text("title") ?? "Task deadline", due));
            }
        if (preferences.ReviewReminder)
            for (int day = 0; day < 30; ++day)
            {
                var date = DateTime.Today.AddDays(day).AddHours(preferences.ReviewHour).AddMinutes(preferences.ReviewMinute);
                if (preferences.WeekdaysOnly && date.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) continue;
                if (TimeZoneInfo.Local.IsInvalidTime(date)) date = date.AddHours(1);
                var due = new DateTimeOffset(date, TimeZoneInfo.Local.GetUtcOffset(date));
                if (due > now) planned.Add(("review-" + date.ToString("yyyy-MM-dd"), "Time to review your tasks", due));
            }
        var nearest = planned.OrderBy(p => p.Due).Take(32).ToList();
        string scope = Scope(library.Workspace);
        string next = scope + "|" + string.Join("|", nearest.Select(p => $"{p.Id}:{p.Title}:{p.Due:O}"));
        if (next == fingerprint) return;
        var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
        var desired = nearest.Select(item =>
        {
            string tag = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(item.Id)))[..16].ToLowerInvariant();
            var content = new ToastContentBuilder().AddArgument("taskId", item.Id).AddArgument("scope", scope)
                .AddText("Takt").AddText(item.Title).GetToastContent().GetXml();
            return new ScheduledToastNotification(content, item.Due) { Id = tag, Tag = tag, Group = scope };
        }).ToList();
        var existing = notifier.GetScheduledToastNotifications().Where(n => n.Group.StartsWith("takt", StringComparison.Ordinal)).ToList();
        static bool Same(ScheduledToastNotification a, ScheduledToastNotification b) =>
            a.Tag == b.Tag && a.Group == b.Group && a.DeliveryTime == b.DeliveryTime && a.Content.GetXml() == b.Content.GetXml();
        // Preserve matching imminent reminders rather than cancelling/recreating
        // the entire schedule whenever one unrelated task changes.
        foreach (var old in existing.Where(old => !desired.Any(item => Same(old, item)))) notifier.RemoveFromSchedule(old);
        foreach (var item in desired.Where(item => !existing.Any(old => Same(old, item))))
            if (item.DeliveryTime > DateTimeOffset.Now) notifier.AddToSchedule(item);
        fingerprint = next;
        if (nearest.Count > 0)
        {
            Directory.CreateDirectory(Preferences.DirectoryPath); File.WriteAllText(marker, "1");
        }
        else if (File.Exists(marker)) File.Delete(marker);
    }
}
