using Takt.Core.Models;
using Takt.Core.Storage;

internal sealed class TaktWindow
{
    private static readonly (string Id, string Label, string Icon)[] Sections =
    [
        ("inbox", "Входящие", "mail-inbox-symbolic"),
        ("today", "Сегодня", "starred-symbolic"),
        ("week", "На неделе", "view-calendar-week-symbolic"),
        ("month", "Месяц", "view-calendar-month-symbolic"),
        ("all", "Все задачи", "view-list-symbolic")
    ];

    private readonly PlannerStore store;
    private readonly Adw.ApplicationWindow window;
    private readonly Gtk.ListBox folders = Gtk.ListBox.New();
    private readonly Gtk.ListBox taskList = Gtk.ListBox.New();
    private readonly Gtk.SearchEntry search = Gtk.SearchEntry.New();
    private readonly Gtk.Entry title = Gtk.Entry.New();
    private readonly Gtk.TextView description = Gtk.TextView.New();
    private readonly Gtk.Label sectionTitle = Gtk.Label.New("");
    private readonly Gtk.Label status = Gtk.Label.New("");
    private readonly Gtk.Stack details = Gtk.Stack.New();
    private readonly Adw.OverlaySplitView navigation = Adw.OverlaySplitView.New();
    private readonly Gtk.Box listColumn = Column(10, 16);
    private readonly Gtk.Button showFolders = Gtk.Button.NewFromIconName("sidebar-show-symbolic");
    private readonly Gtk.Button back = Gtk.Button.NewFromIconName("go-previous-symbolic");
    private readonly Gtk.Button complete = Gtk.Button.NewWithLabel("Выполнить");
    private readonly Gtk.Button today = Gtk.Button.NewWithLabel("На сегодня");
    private readonly List<string> folderIds = [];
    private readonly List<string> taskIds = [];

    private Library library = Library.Empty;
    private string section = "inbox";
    private string? selectedTask;
    private bool rebuilding;
    private bool editing;
    private Layout layout;

    private enum Layout { Wide, Compact, Narrow }

    public TaktWindow(Adw.Application app, PlannerStore store)
    {
        this.store = store;
        window = Adw.ApplicationWindow.New(app);
        window.Title = "Takt";
        window.SetDefaultSize(1100, 680);
        window.SetSizeRequest(360, 420);

        var toolbar = Adw.ToolbarView.New();
        var header = Adw.HeaderBar.New();
        showFolders.TooltipText = "Папки";
        showFolders.OnClicked += (_, _) => navigation.ShowSidebar = !navigation.ShowSidebar;
        header.PackStart(showFolders);
        back.TooltipText = "К списку задач";
        back.OnClicked += (_, _) => BackToList();
        header.PackStart(back);

        var newTask = Gtk.Button.NewWithLabel("Новая задача");
        newTask.OnClicked += (_, _) => CreateTask();
        header.PackStart(newTask);
        search.SetSizeRequest(100, -1);
        search.OnSearchChanged += (_, _) => ShowSearch();
        header.PackEnd(search);
        toolbar.AddTopBar(header);
        toolbar.SetContent(Workspace());
        window.SetContent(toolbar);
        SetLayout(Layout.Wide);
        AddBreakpoint("max-width: 940sp", Layout.Compact);
        AddBreakpoint("max-width: 690sp", Layout.Narrow);
        window.OnCloseRequest += (_, _) => !SaveDraft();
        Refresh();
        LoadEditor();
    }

    public void Present() => window.Present();

    private Gtk.Widget Workspace()
    {
        var sidebar = Column(12, 12);
        var heading = Gtk.Label.New("Папки");
        heading.AddCssClass("heading");
        heading.SetXalign(0);
        sidebar.Append(heading);
        folders.AddCssClass("navigation-sidebar");
        folders.OnRowSelected += (_, e) =>
        {
            if (rebuilding || e.Row is null) return;
            OpenSection(folderIds[e.Row.GetIndex()]);
        };
        sidebar.Append(Scroll(folders));
        var newFolder = Gtk.Button.NewWithLabel("Новая папка…");
        newFolder.OnClicked += (_, _) => CreateFolder();
        sidebar.Append(newFolder);

        sectionTitle.AddCssClass("title-2");
        sectionTitle.SetXalign(0);
        listColumn.Append(sectionTitle);
        taskList.AddCssClass("boxed-list");
        taskList.OnRowSelected += (_, e) =>
        {
            if (!rebuilding && e.Row is { } row) OpenTask(taskIds[row.GetIndex()]);
        };
        taskList.OnRowActivated += (_, e) =>
        {
            if (!rebuilding && !editing) OpenTask(taskIds[e.Row.GetIndex()]);
        };
        var empty = Adw.StatusPage.New();
        empty.Title = "Задач пока нет";
        empty.Description = "Создайте задачу или измените запрос поиска.";
        empty.IconName = "view-list-symbolic";
        taskList.SetPlaceholder(empty);
        listColumn.Append(Scroll(taskList));

        details.AddNamed(Editor(), "task");
        var placeholder = Adw.StatusPage.New();
        placeholder.Title = "Выберите задачу";
        placeholder.Description = "Откройте задачу из списка, чтобы её отредактировать.";
        placeholder.IconName = "document-edit-symbolic";
        details.AddNamed(placeholder, "empty");

        listColumn.SetSizeRequest(240, -1);
        details.SetSizeRequest(290, -1);
        navigation.MinSidebarWidth = 220;
        navigation.MaxSidebarWidth = 240;
        navigation.SetSidebar(sidebar);
        navigation.SetContent(Split(listColumn, details, 300));
        return navigation;
    }

    private void AddBreakpoint(string condition, Layout activeLayout)
    {
        var breakpoint = Adw.Breakpoint.New(Adw.BreakpointCondition.Parse(condition));
        breakpoint.OnApply += (_, _) => SetLayout(activeLayout);
        breakpoint.OnUnapply += (_, _) => SetLayout(Layout.Wide);
        window.AddBreakpoint(breakpoint);
    }

    private void SetLayout(Layout next)
    {
        layout = next;
        navigation.Collapsed = next != Layout.Wide;
        navigation.ShowSidebar = next == Layout.Wide;
        UpdateVisiblePane();
    }

    private void UpdateVisiblePane()
    {
        bool editorOnly = layout == Layout.Narrow && editing;
        listColumn.Visible = !editorOnly;
        details.Visible = layout != Layout.Narrow || editing;
        back.Visible = editorOnly;
        showFolders.Visible = layout != Layout.Wide && !editorOnly;
        search.Visible = !editorOnly;
    }

    private void OpenTask(string id)
    {
        if (id != selectedTask)
        {
            if (!SaveDraft()) { SelectLists(); return; }
            selectedTask = id;
            Refresh();
            LoadEditor();
        }
        editing = true;
        UpdateVisiblePane();
    }

    private void BackToList()
    {
        if (!SaveDraft()) return;
        editing = false;
        Refresh();
        UpdateVisiblePane();
    }

    private Gtk.Widget Editor()
    {
        var content = Column(12, 24);
        var actions = Gtk.Box.New(Gtk.Orientation.Horizontal, 8);
        complete.OnClicked += (_, _) => ToggleCompletion();
        today.OnClicked += (_, _) => ToggleToday();
        actions.Append(complete);
        actions.Append(today);
        content.Append(actions);

        title.PlaceholderText = "Название задачи";
        title.TooltipText = "Название задачи";
        title.AddCssClass("title-3");
        title.OnActivate += (_, _) => SaveAndRefresh();
        content.Append(title);

        var descriptionLabel = Gtk.Label.New("Описание");
        descriptionLabel.SetXalign(0);
        content.Append(descriptionLabel);
        description.WrapMode = Gtk.WrapMode.WordChar;
        description.SetLeftMargin(10);
        description.SetRightMargin(10);
        description.SetTopMargin(8);
        description.SetBottomMargin(8);
        var body = Scroll(description);
        body.HasFrame = true;
        content.Append(body);

        var footer = Gtk.Box.New(Gtk.Orientation.Horizontal, 8);
        var save = Gtk.Button.NewWithLabel("Сохранить");
        save.AddCssClass("suggested-action");
        save.OnClicked += (_, _) => SaveAndRefresh();
        var delete = Gtk.Button.NewWithLabel("Удалить…");
        delete.OnClicked += (_, _) => ConfirmDelete();
        status.SetXalign(0);
        status.SetWrap(true);
        status.Hexpand = true;
        status.AddCssClass("dim-label");
        footer.Append(status);
        footer.Append(delete);
        footer.Append(save);
        content.Append(footer);
        return content;
    }

    private void OpenSection(string id)
    {
        if (!SaveDraft()) { SelectLists(); return; }
        section = id;
        selectedTask = null;
        editing = false;
        if (layout != Layout.Wide) navigation.ShowSidebar = false;
        Refresh();
        LoadEditor();
        UpdateVisiblePane();
    }

    private void ShowSearch()
    {
        if (!SaveDraft()) return;
        Refresh();
    }

    private void CreateTask()
    {
        if (!SaveDraft()) return;
        var task = TaskRules.CreateTask("Новая задача", section);
        try
        {
            Apply([task]);
            search.SetText("");
            selectedTask = task.Id;
            editing = true;
            Refresh();
            LoadEditor();
            UpdateVisiblePane();
            title.GrabFocus();
            title.SelectRegion(0, -1);
        }
        catch (Exception error) { ShowError(error); }
    }

    private void CreateFolder()
    {
        if (!SaveDraft()) return;
        var dialog = Adw.MessageDialog.New(window, "Новая папка", "Введите название папки.");
        var entry = Gtk.Entry.New();
        entry.PlaceholderText = "Название";
        entry.MaxLength = 80;
        dialog.ExtraChild = entry;
        dialog.AddResponse("cancel", "Отмена");
        dialog.AddResponse("create", "Создать");
        dialog.SetDefaultResponse("create");
        dialog.SetCloseResponse("cancel");
        dialog.SetResponseEnabled("create", false);
        entry.OnChanged += (_, _) => dialog.SetResponseEnabled("create", !string.IsNullOrWhiteSpace(entry.GetText()));
        dialog.OnResponse += (_, e) =>
        {
            if (e.Response != "create") return;
            try
            {
                int order = library.Folders.Select(f => f.Number("sortOrder")).DefaultIfEmpty(-1).Max() + 1;
                var folder = TaskRules.CreateFolder(entry.GetText(), order);
                Apply([folder]);
                OpenSection(folder.Id);
            }
            catch (Exception error) { ShowError(error); }
        };
        dialog.Present();
        entry.GrabFocus();
    }

    private void ToggleCompletion()
    {
        UpdateTask((task) => TaskRules.Update(task, "completedAt", task.Completed ? Wire.Null : Wire.Value(Wire.Time())));
    }

    private void ToggleToday()
    {
        UpdateTask((task) => TaskRules.Update(task, "focusDay", task.Focused(LocalDate)
            ? Wire.Null : Wire.Value("9999-12-31")));
    }

    private void UpdateTask(Func<Entity, Edit> edit)
    {
        if (CurrentTask is not { } task || !SaveDraft()) return;
        try
        {
            Apply([edit(task)]);
            Refresh();
            LoadEditor();
        }
        catch (Exception error) { ShowError(error); }
    }

    private void ConfirmDelete()
    {
        if (CurrentTask is not { } task || !SaveDraft()) return;
        var dialog = Adw.MessageDialog.New(window, "Удалить задачу?", task.Text("title"));
        dialog.AddResponse("cancel", "Отмена");
        dialog.AddResponse("delete", "Удалить");
        dialog.SetCloseResponse("cancel");
        dialog.SetResponseAppearance("delete", Adw.ResponseAppearance.Destructive);
        dialog.OnResponse += (_, e) =>
        {
            if (e.Response != "delete") return;
            try
            {
                Apply(TaskRules.DeleteTask(library, task));
                selectedTask = null;
                editing = false;
                Refresh();
                LoadEditor();
                UpdateVisiblePane();
            }
            catch (Exception error) { ShowError(error); }
        };
        dialog.Present();
    }

    private Entity? CurrentTask => library.Tasks.FirstOrDefault(t => t.Id == selectedTask);
    private static DateOnly LocalDate => DateOnly.FromDateTime(DateTime.Today);

    private void LoadEditor()
    {
        var task = CurrentTask;
        details.VisibleChildName = task is null ? "empty" : "task";
        if (task is null) return;
        title.SetText(task.Text("title") ?? "");
        description.GetBuffer().SetText(task.Text("description") ?? "", -1);
        complete.Label = task.Completed ? "Вернуть в работу" : "Выполнить";
        today.Label = task.Focused(LocalDate) ? "Убрать из «Сегодня»" : "На сегодня";
        status.Label_ = "";
    }

    private bool SaveDraft()
    {
        if (CurrentTask is not { } task) return true;
        var buffer = description.GetBuffer();
        buffer.GetBounds(out var first, out var last);
        string body = buffer.GetText(first, last, true);
        string value = title.GetText();
        var changes = new List<Edit>(2);
        if (!string.Equals(task.Text("title") ?? "", value, StringComparison.Ordinal))
            changes.Add(TaskRules.Update(task, "title", Wire.Value(value)));
        if (!string.Equals(task.Text("description") ?? "", body, StringComparison.Ordinal))
            changes.Add(TaskRules.Update(task, "description", Wire.Value(body)));
        if (changes.Count == 0) return true;
        try
        {
            Apply(changes);
            status.Label_ = "Сохранено";
            return true;
        }
        catch (Exception error)
        {
            ShowError(error);
            return false;
        }
    }

    private void SaveAndRefresh()
    {
        if (SaveDraft()) Refresh();
    }

    private void Apply(IReadOnlyList<Edit> edits)
    {
        store.EditAsync(library.Workspace, edits, 0).GetAwaiter().GetResult();
        library = store.ReadAsync().GetAwaiter().GetResult();
    }

    private void Refresh()
    {
        library = store.ReadAsync().GetAwaiter().GetResult();
        rebuilding = true;
        try
        {
            folders.RemoveAll();
            taskList.RemoveAll();
            folderIds.Clear();
            taskIds.Clear();
            foreach (var (id, label, symbol) in Sections)
                AddFolderRow(id, label, symbol);
            foreach (var folder in library.Folders)
                AddFolderRow(folder.Id, folder.Text("name") ?? "Папка", "folder-symbolic");
            sectionTitle.Label_ = Sections.FirstOrDefault(s => s.Id == section).Label ??
                library.Folders.FirstOrDefault(f => f.Id == section)?.Text("name") ?? "Папка";
            foreach (var item in library.InSection(section, search.GetText(), LocalDate).OrderBy(t => t.Completed))
            {
                string label = item.Text("title") is { Length: > 0 } name ? name : "Без названия";
                var row = TextRow(label, item.Completed ? "emblem-ok-symbolic" :
                    item.Focused(LocalDate) ? "starred-symbolic" : "text-x-generic-symbolic",
                    item.Completed ? "Выполнено" : null);
                taskList.Append(row);
                taskIds.Add(item.Id);
            }
            SelectRows();
        }
        finally { rebuilding = false; }
    }

    private void AddFolderRow(string id, string label, string symbol)
    {
        int count = library.InSection(id, "", LocalDate).Count(t => !t.Completed);
        folders.Append(TextRow(label, symbol, count.ToString()));
        folderIds.Add(id);
    }

    private void SelectLists()
    {
        rebuilding = true;
        try { SelectRows(); }
        finally { rebuilding = false; }
    }

    private void SelectRows()
    {
        folders.SelectRow(folders.GetRowAtIndex(folderIds.IndexOf(section)));
        int index = selectedTask is null ? -1 : taskIds.IndexOf(selectedTask);
        taskList.SelectRow(index < 0 ? null : taskList.GetRowAtIndex(index));
    }

    private void ShowError(Exception error)
    {
        Console.Error.WriteLine(error.Message);
        var dialog = Adw.MessageDialog.New(window, "Не удалось сохранить изменения", error.Message);
        dialog.AddResponse("close", "Закрыть");
        dialog.SetCloseResponse("close");
        dialog.Present();
    }

    internal void Check()
    {
        Present();
        CreateTask();
        title.SetText("Проверка редактора Linux");
        description.GetBuffer().SetText("Текст после переключения", -1);
        OpenSection("all");
        var persisted = library.Tasks.Single(t => t.Text("title") == "Проверка редактора Linux");
        if (persisted.Text("description") != "Текст после переключения")
            throw new InvalidDataException("The workspace did not save the editor.");

        OpenTask(persisted.Id);
        description.GetBuffer().SetText("Черновик в узком окне", -1);
        SetLayout(Layout.Narrow);
        if (listColumn.Visible || !details.Visible || !back.Visible)
            throw new InvalidOperationException("The editor should occupy the narrow window.");
        BackToList();
        if (!listColumn.Visible || details.Visible ||
            library.Tasks.Single().Text("description") != "Черновик в узком окне")
            throw new InvalidOperationException("Returning to the list lost the draft.");
        OpenTask(persisted.Id);
        title.SetText("Последняя правка перед закрытием");
        window.Close();
        if (store.ReadAsync().GetAwaiter().GetResult().Tasks.Single().Text("title") != "Последняя правка перед закрытием")
            throw new InvalidOperationException("Closing the window did not save the draft.");
        Console.WriteLine("GTK workspace saved edits on navigation, narrow Back, and window close.");
    }

    private static Gtk.Widget TextRow(string value, string icon, string? info)
    {
        var row = Gtk.Box.New(Gtk.Orientation.Horizontal, 10);
        SetMargins(row, 10);
        row.Append(Gtk.Image.NewFromIconName(icon));
        var name = Gtk.Label.New(value);
        name.SetXalign(0);
        name.SetEllipsize(Pango.EllipsizeMode.End);
        name.Hexpand = true;
        row.Append(name);
        if (info is not null)
        {
            var metadata = Gtk.Label.New(info);
            metadata.AddCssClass("dim-label");
            row.Append(metadata);
        }
        return row;
    }

    private static Gtk.Box Column(int spacing, int margin)
    {
        var box = Gtk.Box.New(Gtk.Orientation.Vertical, spacing);
        SetMargins(box, margin);
        return box;
    }

    private static void SetMargins(Gtk.Widget widget, int margin)
    {
        widget.MarginStart = widget.MarginEnd = widget.MarginTop = widget.MarginBottom = margin;
    }

    private static Gtk.ScrolledWindow Scroll(Gtk.Widget child)
    {
        var scroller = Gtk.ScrolledWindow.New();
        scroller.Vexpand = true;
        scroller.SetPolicy(Gtk.PolicyType.Never, Gtk.PolicyType.Automatic);
        scroller.SetChild(child);
        return scroller;
    }

    private static Gtk.Paned Split(Gtk.Widget left, Gtk.Widget right, int leftWidth)
    {
        var pane = Gtk.Paned.New(Gtk.Orientation.Horizontal);
        pane.SetStartChild(left);
        pane.SetEndChild(right);
        pane.SetPosition(leftWidth);
        pane.SetResizeStartChild(false);
        pane.SetShrinkStartChild(false);
        pane.SetShrinkEndChild(false);
        return pane;
    }
}
