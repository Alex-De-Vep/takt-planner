using CommunityToolkit.WinUI.Notifications;
using System.Security.Cryptography;
using System.Text;
using Takt.Core.Calendar;
using global::Windows.UI.Notifications;

namespace Takt.Windows.Services;

// Calendar and task notifications must use disjoint groups. Each scheduler gets
// 32 slots, reserving a combined budget of 64. Refresh on edits, activation and timer.
public sealed class CalendarReminders
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public static string Scope(string workspace) => "cale" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(LibraryDirectories.Active == LibraryDirectories.Root ? workspace : LibraryDirectories.Active + "|" + workspace)))[..12].ToLowerInvariant();
    public async Task UpdateAsync(ICalendarProvider provider, string workspace)
    {
        await gate.WaitAsync();
        try
        {
            var snapshot = await provider.ReadAsync(workspace);
            string scope = Scope(workspace); var now = DateTimeOffset.Now;
            var planned = snapshot.Events.Where(e => e.CanEdit).SelectMany(e => e.Alarms.Select(a => (Entry: e, Alarm: a, Due: a.Due(e))))
                .Where(a => a.Due > now).OrderBy(a => a.Due).ThenBy(a => a.Entry.Id, StringComparer.Ordinal).ThenBy(a => a.Alarm.Id, StringComparer.Ordinal).Take(32).ToList();
            var notifier = ToastNotificationManagerCompat.CreateToastNotifier();
            var desired = planned.Select(item =>
            {
                string tag = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(item.Entry.Id + "|" + item.Alarm.Id)))[..16].ToLowerInvariant();
                var content = new ToastContentBuilder().AddArgument("calendarEventId", item.Entry.Id).AddArgument("calendarScope", scope)
                    .AddText("Takt · Calendar").AddText(item.Entry.Title).GetToastContent().GetXml();
                return new ScheduledToastNotification(content, item.Due) { Id = tag, Tag = tag, Group = scope };
            }).ToList();
            var existing = notifier.GetScheduledToastNotifications().Where(n => n.Group.StartsWith("cale", StringComparison.Ordinal)).ToList();
            static bool Same(ScheduledToastNotification a, ScheduledToastNotification b) => a.Group == b.Group && a.Tag == b.Tag && a.DeliveryTime == b.DeliveryTime && a.Content.GetXml() == b.Content.GetXml();
            foreach (var old in existing.Where(n => !desired.Any(d => Same(n, d)))) notifier.RemoveFromSchedule(old);
            foreach (var item in desired.Where(d => !existing.Any(n => Same(n, d)))) if (item.DeliveryTime > DateTimeOffset.Now) notifier.AddToSchedule(item);
        }
        finally { gate.Release(); }
    }
}
