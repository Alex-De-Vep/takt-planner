using Takt.Core.Models;
using Takt.Core.Storage;

const string id = "io.github.alex_de_vep.Takt";
if (args is ["--check-storage", var testFile]) return CheckStorage(testFile);
if (args is not [] and not ["--check-window"])
{
    Console.Error.WriteLine("Usage: Takt.Linux [--check-window | --check-storage <new-file>]");
    return 2;
}

var dataHome = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
if (!Path.IsPathFullyQualified(dataHome ?? ""))
    dataHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
var path = Path.Combine(dataHome!, "takt", "tasks.sqlite3");

try
{
    Adw.Module.Initialize();
    Gtk.Module.Initialize();
    if (args is ["--check-window"])
    {
        if (Environment.GetEnvironmentVariable("XDG_DATA_HOME") != dataHome || File.Exists(path))
            throw new InvalidOperationException("Use a new isolated XDG_DATA_HOME for window checks.");
        var probe = Adw.Application.New(id + ".Smoke", Gio.ApplicationFlags.NonUnique);
        probe.OnActivate += (_, _) =>
        {
            try
            {
                using var store = OpenStore(path);
                var workspace = new TaktWindow(probe, store);
                workspace.Check();
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                Environment.ExitCode = 1;
            }
            finally { probe.Quit(); }
        };
        int result = probe.RunWithSynchronizationContext(null);
        return Environment.ExitCode != 0 ? Environment.ExitCode : result;
    }

    var app = Adw.Application.New(id, Gio.ApplicationFlags.FlagsNone);
    PlannerStore? store = null;
    TaktWindow? window = null;
    app.OnActivate += (_, _) => (window ??= new TaktWindow(app, store ??= OpenStore(path))).Present();
    try { return app.RunWithSynchronizationContext(null); }
    finally { store?.Dispose(); }
}
catch (Exception error)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}

static PlannerStore OpenStore(string filename)
{
    var store = new PlannerStore(filename);
    try
    {
        store.InitializeAsync().GetAwaiter().GetResult();
        return store;
    }
    catch
    {
        store.Dispose();
        throw;
    }
}

static int CheckStorage(string filename)
{
    if (File.Exists(filename)) throw new IOException("The test library already exists.");
    var folder = TaskRules.CreateFolder("Проверочная папка", 0);
    var task = TaskRules.CreateTask("Проверка сохранения", folder.Id);
    using (var store = OpenStore(filename))
    {
        store.EditAsync("local", [folder, task], 0).GetAwaiter().GetResult();
        var entity = store.ReadAsync().GetAwaiter().GetResult().Tasks.Single();
        store.EditAsync("local", [TaskRules.Update(entity, "description", Wire.Value("Текст после перезапуска")),
            TaskRules.Update(entity, "completedAt", Wire.Value(Wire.Time()))], 0).GetAwaiter().GetResult();
    }
    using (var store = OpenStore(filename))
    {
        var library = store.ReadAsync().GetAwaiter().GetResult();
        var persisted = library.Tasks.Single();
        if (!persisted.Completed || library.Location(persisted) != folder.Id ||
            persisted.Text("description") != "Текст после перезапуска")
            throw new InvalidDataException("The task or its folder was not restored.");
    }
    Console.WriteLine("Local task and folder persisted across reopen.");
    return 0;
}
