using System.Text.Json;

namespace Takt.Windows.Services;

public sealed record Preferences(string Theme = "Default", bool DeadlineReminders = false,
    int DateOnlyHour = 9, bool ReviewReminder = false, int ReviewHour = 18, bool WeekdaysOnly = true, int ReviewMinute = 0, bool WelcomeSeen = false)
{
    public static string DirectoryPath => LibraryDirectories.Active;
    private static string FilePath => Path.Combine(DirectoryPath, "preferences.json");
    public static Preferences Read()
    {
        if (!File.Exists(FilePath)) return new();
        var value = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new();
        return value with { Theme = value.Theme is "Default" or "Light" or "Dark" ? value.Theme : "Default", DateOnlyHour = Math.Clamp(value.DateOnlyHour, 0, 23), ReviewHour = Math.Clamp(value.ReviewHour, 0, 23), ReviewMinute = Math.Clamp(value.ReviewMinute, 0, 59) };
    }
    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
}
