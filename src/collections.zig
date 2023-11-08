const std = @import("std");

const utils = @import("utils.zig");
const content_map = @import("collections/content_map.zig");
const FileSystem = @import("FileSystem.zig");
const Topology = @import("collections/Topology.zig");
const indexing = @import("collections/indexing.zig");

const IndexContainer = indexing.IndexContainer;
const eql = std.mem.eql;
const ArrayList = std.ArrayList;

pub const Tag = Topology.Tag;
pub const Type = enum { Directory, Journal, Tasklist };
pub const ItemType = enum { Note, Day, Task };
pub const Ordering = enum {
    Modified,
    Created,
    Due,
};

pub const MaybeCollection = struct {
    journal: ?*Collection = null,
    directory: ?*Collection = null,
    tasklist: ?*Collection = null,
};

pub const MaybeItem = struct {
    day: ?Item = null,
    note: ?Item = null,
    task: ?Item = null,

    pub const Error = error{TooManyActive};

    pub fn numActive(self: MaybeItem) usize {
        var num: usize = 0;
        if (self.day != null) num += 1;
        if (self.note != null) num += 1;
        if (self.task != null) num += 1;
        return num;
    }

    pub fn getActive(self: MaybeItem) !Item {
        if (self.numActive() != 1) return Error.TooManyActive;

        if (self.day) |i| return i;
        if (self.note) |i| return i;
        if (self.task) |i| return i;
        unreachable;
    }

    pub fn collectionName(self: MaybeItem) ![]const u8 {
        if (self.numActive() != 1) return Error.TooManyActive;

        if (self.day) |d| {
            return d.Day.journal.description.name;
        }
        if (self.note) |n| {
            return n.Note.dir.description.name;
        }
        if (self.task) |t| {
            return t.Task.tasklist.info.name;
        }
        unreachable;
    }

    pub fn collectionType(self: MaybeItem) !Type {
        if (self.numActive() != 1) return Error.TooManyActive;

        if (self.day) |_| {
            return .Journal;
        }
        if (self.note) |_| {
            return .Directory;
        }
        if (self.task) |_| {
            return .Tasklist;
        }
        unreachable;
    }
};

fn childPath(
    alloc: std.mem.Allocator,
    container_path: []const u8,
    name: []const u8,
    comptime ext: []const u8,
) ![]const u8 {
    const filename = try std.mem.concat(
        alloc,
        u8,
        &.{ name, ext },
    );
    defer alloc.free(filename);
    return try std.fs.path.join(
        alloc,
        &.{ container_path, filename },
    );
}

const Directory = struct {
    pub const ContentMap = content_map.ContentMap([]const u8);
    pub const DEFAULT_FILE_EXTENSION = ".md";

    mem: std.heap.ArenaAllocator,
    fs: FileSystem,
    description: *Topology.Description,
    content: ContentMap,

    pub fn readContent(d: *Directory, note: *Topology.InfoScheme) ![]const u8 {
        return d.content.get(note.name) orelse {
            var alloc = d.content.allocator();
            const content = try d.fs.readFileAlloc(alloc, note.path);
            try d.content.putMove(note.name, content);
            return d.content.get(note.name).?;
        };
    }

    inline fn addNote(
        d: *Directory,
        info: Topology.InfoScheme,
    ) !*Topology.InfoScheme {
        var alloc = d.mem.allocator();
        const info_ptr = try utils.push(
            Topology.InfoScheme,
            alloc,
            &d.description.infos,
            info,
        );

        // write a template to the file
        try d.fs.overwrite(info.path, "");

        return info_ptr;
    }

    pub fn newNote(d: *Directory, name: []const u8) !Item {
        var alloc = d.mem.allocator();
        const owned_name = try alloc.dupe(u8, name);

        const now = utils.now();
        const info: Topology.InfoScheme = .{
            .modified = now,
            .created = now,
            .name = owned_name,
            .path = try childPath(
                alloc,
                d.description.path,
                owned_name,
                DEFAULT_FILE_EXTENSION,
            ),
            .tags = try utils.emptyTagList(alloc),
        };

        var note = try d.addNote(info);
        return .{ .Note = .{ .dir = d, .note = note } };
    }

    pub fn init(alloc: std.mem.Allocator, d: *Topology.Description, fs: FileSystem) !Directory {
        var mem = std.heap.ArenaAllocator.init(alloc);
        errdefer mem.deinit();
        var content = try ContentMap.init(alloc);
        errdefer content.deinit();

        return .{
            .mem = mem,
            .fs = fs,
            .description = d,
            .content = content,
        };
    }

    pub fn deinit(d: *Directory) void {
        d.mem.deinit();
        d.content.deinit();
        d.* = undefined;
    }
};

const Journal = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const ContentMap = content_map.ContentMap([]Entry);
    pub const Entry = Topology.Entry;

    mem: std.heap.ArenaAllocator,
    fs: FileSystem,
    description: *Topology.Description,
    content: ContentMap,
    index: IndexContainer,

    pub fn readEntries(j: *Journal, day: *Topology.InfoScheme) ![]Entry {
        return j.content.get(day.name) orelse {
            var alloc = j.content.allocator();
            const string = try j.fs.readFileAlloc(alloc, day.path);
            var entries = try Topology.parseEntries(alloc, string);
            try j.content.putMove(day.name, entries);
            return j.content.get(day.name).?;
        };
    }

    pub fn addEntryToDay(j: *Journal, day: *Topology.InfoScheme, entry: Entry) !*Entry {
        var entries = j.content.get(day.name) orelse try j.readEntries(day);
        const ptr = try utils.push(Entry, j.content.allocator(), &entries, entry);
        try j.content.putMove(day.name, entries);
        return ptr;
    }

    inline fn addDay(
        j: *Journal,
        info: Topology.InfoScheme,
    ) !*Topology.InfoScheme {
        var alloc = j.mem.allocator();
        const info_ptr = try utils.push(
            Topology.InfoScheme,
            alloc,
            &j.description.infos,
            info,
        );

        // write a template to the file
        try j.fs.overwrite(info.path, "{\"items\":[]}");

        return info_ptr;
    }

    pub fn getIndex(j: *Journal, index: usize) ?Item {
        const name = j.index.get(index) orelse
            return null;

        var info = for (j.description.infos) |*i| {
            if (std.mem.eql(u8, i.name, name)) break i;
        } else unreachable;

        return .{ .Day = .{ .journal = j, .day = info } };
    }

    pub fn newDay(j: *Journal, name: []const u8) !Item {
        var alloc = j.mem.allocator();
        const owned_name = try alloc.dupe(u8, name);

        const now = utils.now();
        const info: Topology.InfoScheme = .{
            .modified = now,
            .created = now,
            .name = owned_name,
            .path = try childPath(
                alloc,
                j.description.path,
                owned_name,
                DEFAULT_FILE_EXTENSION,
            ),
            .tags = try utils.emptyTagList(alloc),
        };

        var day = try j.addDay(info);
        return .{ .Day = .{ .journal = j, .day = day } };
    }

    pub fn init(alloc: std.mem.Allocator, d: *Topology.Description, fs: FileSystem) !Journal {
        var mem = std.heap.ArenaAllocator.init(alloc);
        errdefer mem.deinit();
        var content = try ContentMap.init(alloc);
        errdefer content.deinit();
        var index = try indexing.makeIndex(alloc, d.infos);
        errdefer index.deinit();

        return .{
            .mem = mem,
            .fs = fs,
            .description = d,
            .content = content,
            .index = index,
        };
    }

    pub fn deinit(j: *Journal) void {
        j.mem.deinit();
        j.content.deinit();
        j.index.deinit();
        j.* = undefined;
    }
};

pub const TASKLIST_ROOT_DIRECTORY = "tasklists";
const Tasklist = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const Task = Topology.Task;

    mem: std.heap.ArenaAllocator,
    fs: FileSystem,
    info: *Topology.TasklistInfo,
    tasks: ?[]Task,
    index: ?IndexContainer,

    pub const TaskOptions = struct {
        due: ?u64 = null,
        importance: Task.Importance = .low,
        details: []const u8 = "",
    };

    pub fn addTask(self: *Tasklist, title: []const u8, options: TaskOptions) !*Task {
        _ = try self.readTasks();

        var alloc = self.mem.allocator();
        const now = utils.now();
        const owned_title = try alloc.dupe(u8, title);
        const owned_details = try alloc.dupe(u8, options.details);

        const new_task: Task = .{
            .title = owned_title,
            .details = owned_details,
            .created = now,
            .modified = now,
            .completed = null,
            .due = options.due,
            .importance = options.importance,
            .tags = try utils.emptyTagList(alloc),
            .done = false,
        };

        return try utils.push(Task, alloc, &(self.tasks.?), new_task);
    }

    pub fn readTasks(self: *Tasklist) ![]Task {
        return self.tasks orelse {
            var alloc = self.mem.allocator();
            const string = try self.fs.readFileAlloc(
                alloc,
                self.info.path,
            );
            self.tasks = try Topology.parseTasks(alloc, string);
            try self.determineIndexes();
            return self.tasks.?;
        };
    }

    fn determineIndexes(self: *Tasklist) !void {
        var alloc = self.mem.child_allocator;

        const tasks = self.tasks.?;
        std.sort.insertion(Task, tasks, {}, sortCanonical);
        // std.mem.reverse(Task, tasks);

        var index = IndexContainer.init(alloc);
        errdefer index.deinit();

        var counter: usize = 0;
        for (tasks) |task| {
            if (task.done) continue;
            try index.put(counter, task.title);
            counter += 1;
        }

        self.index = index;
    }

    pub fn getIndex(t: *Tasklist, index: usize) ?Item {
        const title = t.index.?.get(index) orelse
            return null;

        var task = for (t.tasks.?) |*task| {
            if (std.mem.eql(u8, title, task.title)) break task;
        } else unreachable;

        return .{ .Task = .{ .tasklist = t, .task = task } };
    }

    pub fn invertIndexMap(
        t: *const Tasklist,
        alloc: std.mem.Allocator,
    ) !std.StringHashMap(usize) {
        var map = std.StringHashMap(usize).init(alloc);
        errdefer map.deinit();

        var itt = t.index.?.iterator();

        while (itt.next()) |entry| {
            try map.put(entry.value_ptr.*, entry.key_ptr.*);
        }

        return map;
    }

    fn sortDue(_: void, lhs: Task, rhs: Task) bool {
        const lhs_due = lhs.due;
        const rhs_due = rhs.due;
        if (lhs_due == null and rhs_due == null) return true;
        if (lhs_due == null) return false;
        if (rhs_due == null) return true;
        return lhs_due.? < rhs_due.?;
    }

    fn sortCanonical(_: void, lhs: Task, rhs: Task) bool {
        const due = sortDue({}, lhs, rhs);
        const both_same =
            (lhs.due == null and rhs.due == null) or (lhs.due != null and rhs.due != null);
        if (both_same and lhs.due == rhs.due) {
            // if they are both due at the same time, we sort lexographically
            return std.ascii.lessThanIgnoreCase(lhs.title, rhs.title);
        }
        return due;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        info: *Topology.TasklistInfo,
        fs: FileSystem,
    ) !Tasklist {
        var mem = std.heap.ArenaAllocator.init(alloc);
        errdefer mem.deinit();

        return .{
            .mem = mem,
            .fs = fs,
            .info = info,
            .tasks = null,
            .index = null,
        };
    }

    pub fn deinit(t: *Tasklist) void {
        if (t.index) |*i| i.deinit();
        t.mem.deinit();
        t.* = undefined;
    }
};

pub const Item = union(ItemType) {
    Note: struct {
        dir: *Directory,
        note: *Topology.InfoScheme,

        pub fn read(self: @This()) ![]const u8 {
            return try self.dir.readContent(self.note);
        }
    },

    Day: struct {
        journal: *Journal,
        day: *Topology.InfoScheme,

        pub fn read(self: @This()) ![]Topology.Entry {
            return try self.journal.readEntries(self.day);
        }

        pub fn add(self: @This(), entry_text: []const u8) !*Journal.Entry {
            var alloc = self.journal.content.allocator();
            const now = utils.now();
            const owned_text = try alloc.dupe(u8, entry_text);

            const entry: Journal.Entry = .{
                .created = now,
                .modified = now,
                .item = owned_text,
                .tags = try utils.emptyTagList(alloc),
            };

            return try self.journal.addEntryToDay(self.day, entry);
        }

        pub fn removeEntryByIndex(self: @This(), index: usize) !void {
            var entries = try self.read();
            utils.moveToEnd(Topology.Entry, entries, index);
            entries.len -= 1;
            try self.journal.content.put(self.day.name, entries);
        }
    },

    Task: struct {
        tasklist: *Tasklist,
        task: *Tasklist.Task,

        pub fn status(self: @This()) Tasklist.Task.Status {
            return self.task.status();
        }

        pub fn isDone(self: @This()) bool {
            return self.task.done;
        }

        pub fn setDone(self: @This()) void {
            self.task.done = true;
            self.task.completed = utils.now();
        }

        pub fn setTodo(self: @This()) void {
            self.task.done = false;
            self.task.completed = null;
        }
    },

    inline fn commonRemove(
        fs: FileSystem,
        infos: *[]Topology.InfoScheme,
        name: []const u8,
        path: []const u8,
    ) !void {
        const index = for (infos.*, 0..) |info, j| {
            if (std.mem.eql(u8, info.name, name)) break j;
        } else unreachable;
        utils.moveToEnd(Topology.InfoScheme, infos.*, index);
        infos.len -= 1;

        try fs.removeFile(path);
    }

    pub fn remove(item: Item) !void {
        switch (item) {
            .Note => |n| {
                try commonRemove(
                    n.dir.fs,
                    &n.dir.description.infos,
                    n.note.name,
                    n.note.path,
                );
            },
            .Day => |d| {
                try commonRemove(
                    d.journal.fs,
                    &d.journal.description.infos,
                    d.day.name,
                    d.day.path,
                );
            },
            .Task => |t| {
                var tasks = &t.tasklist.tasks.?;
                const index = for (0.., tasks.*) |j, p| {
                    if (std.mem.eql(u8, p.title, t.task.title)) break j;
                } else unreachable;
                utils.moveToEnd(Topology.Task, tasks.*, index);
                tasks.len -= 1;
            },
        }
    }

    pub fn rename(item: Item, new_name: []const u8) !void {
        switch (item) {
            .Note => |n| {
                // update name, path, and rename file
                n.note.name = new_name;
                const old_path = n.note.path;

                n.note.path = try childPath(
                    n.dir.mem.allocator(),
                    n.dir.description.path,
                    new_name,
                    Directory.DEFAULT_FILE_EXTENSION,
                );

                try n.dir.fs.move(old_path, n.note.path);
            },
            .Day => |d| {
                // update name, path, and rename file
                d.day.name = new_name;
                const old_path = d.day.path;

                d.day.path = try childPath(
                    d.journal.mem.allocator(),
                    d.journal.description.path,
                    new_name,
                    Journal.DEFAULT_FILE_EXTENSION,
                );

                try d.journal.fs.move(old_path, d.day.path);
            },
            .Task => |t| t.task.title = new_name,
        }
    }

    pub fn getCreated(item: Item) u64 {
        return switch (item) {
            .Note => |n| n.note.created,
            .Day => |d| d.day.created,
            .Task => |t| t.task.created,
        };
    }

    pub fn getModified(item: Item) u64 {
        return switch (item) {
            .Note => |n| n.note.modified,
            .Day => |d| d.day.modified,
            .Task => |t| t.task.modified,
        };
    }

    pub fn getDue(item: Item) ?u64 {
        return switch (item) {
            .Task => |t| t.task.due,
            else => unreachable,
        };
    }

    pub fn getName(item: Item) []const u8 {
        return switch (item) {
            .Note => |n| n.note.name,
            .Day => |d| d.day.name,
            .Task => |t| t.task.title,
        };
    }

    pub fn getPath(item: Item) []const u8 {
        return switch (item) {
            .Note => |n| n.note.path,
            .Day => |d| d.day.path,
            .Task => unreachable,
        };
    }

    fn sortDue(_: void, lhs: Item, rhs: Item) bool {
        return Tasklist.sortCanonical({}, lhs.Task.task.*, rhs.Task.task.*);
    }

    fn sortCreated(_: void, lhs: Item, rhs: Item) bool {
        const lhs_created = lhs.getCreated();
        const rhs_created = rhs.getCreated();
        return lhs_created < rhs_created;
    }

    fn sortModified(_: void, lhs: Item, rhs: Item) bool {
        const lhs_modified = lhs.getModified();
        const rhs_modified = rhs.getModified();
        return lhs_modified < rhs_modified;
    }

    inline fn parent(item: Item) Collection {
        switch (item) {
            .Day => |d| return .{ .Journal = d.journal.* },
            .Note => |n| return .{ .Directory = n.dir.* },
            .Task => |t| return .{ .Tasklist = t.tasklist.* },
        }
    }

    pub fn collectionName(item: Item) []const u8 {
        return item.parent().getName();
    }
};

pub const Collection = union(Type) {
    Directory: Directory,
    Journal: Journal,
    Tasklist: Tasklist,

    pub fn allocator(c: *Collection) std.mem.Allocator {
        switch (c.*) {
            inline else => |*i| return i.mem.allocator(),
        }
    }

    inline fn getIndexByProperty(
        c: *Collection,
        comptime C: Type,
        comptime property: []const u8,
        value: []const u8,
    ) ?usize {
        switch (C) {
            .Tasklist => {
                const tasks = c.Tasklist.tasks orelse return null;
                for (0.., tasks) |i, task| {
                    if (eql(u8, @field(task, property), value))
                        return i;
                }
            },
            inline else => {
                switch (c.*) {
                    .Tasklist => unreachable,
                    inline else => |*s| {
                        for (0.., s.description.infos) |i, info| {
                            if (eql(u8, @field(info, property), value))
                                return i;
                        }
                    },
                }
            },
        }
        return null;
    }

    inline fn getByIndex(c: *Collection, index: usize) ?Item {
        switch (c.*) {
            .Tasklist => |*s| {
                var tasks = s.tasks orelse return null;
                if (index >= tasks.len)
                    return null;
                var task = &tasks[index];
                return .{ .Task = .{ .tasklist = s, .task = task } };
            },
            .Directory => |*s| {
                if (index >= s.description.infos.len)
                    return null;
                const info = &s.description.infos[index];
                return .{ .Note = .{ .dir = s, .note = info } };
            },
            .Journal => |*s| {
                if (index >= s.description.infos.len)
                    return null;
                const info = &s.description.infos[index];
                return .{ .Day = .{ .journal = s, .day = info } };
            },
        }
    }

    inline fn getSize(c: *const Collection) usize {
        switch (c.*) {
            .Tasklist => |s| {
                const tasks = s.tasks orelse return 0;
                return tasks.len;
            },
            inline else => |s| return s.description.infos.len,
        }
    }

    pub fn get(c: *Collection, name: []const u8) ?Item {
        const index = switch (c.*) {
            .Tasklist => c.getIndexByProperty(.Tasklist, "title", name),
            .Journal => c.getIndexByProperty(.Journal, "name", name),
            .Directory => c.getIndexByProperty(.Directory, "name", name),
        };
        return c.getByIndex(index orelse return null);
    }

    pub fn getByPath(c: *Collection, path: []const u8) ?Item {
        const index = switch (c.*) {
            .Tasklist => unreachable,
            .Journal => c.getIndexByProperty(.Journal, "path", path),
            .Directory => c.getIndexByProperty(.Directory, "path", path),
        };
        return c.getByIndex(index orelse return null);
    }

    pub fn getAll(c: *Collection, alloc: std.mem.Allocator) ![]Item {
        const N = c.getSize();
        var items = try alloc.alloc(Item, N);
        errdefer alloc.free(items);

        for (0..N) |i| items[i] = c.getByIndex(i).?;

        return items;
    }

    pub fn readAll(c: *Collection) !void {
        switch (c.*) {
            .Tasklist => |*t| {
                _ = try t.readTasks();
            },
            else => {},
        }
    }

    pub fn init(
        alloc: std.mem.Allocator,
        comptime what: Type,
        data: anytype,
        fs: FileSystem,
    ) !Collection {
        switch (what) {
            .Directory => return .{
                .Directory = try Directory.init(alloc, data, fs),
            },
            .Journal => return .{
                .Journal = try Journal.init(alloc, data, fs),
            },
            .Tasklist => return .{
                .Tasklist = try Tasklist.init(alloc, data, fs),
            },
        }
    }

    pub fn deinit(c: *Collection) void {
        switch (c.*) {
            inline else => |*i| i.deinit(),
        }
        c.* = undefined;
    }

    pub fn getName(c: *const Collection) []const u8 {
        switch (c.*) {
            .Tasklist => |s| return s.info.name,
            inline else => |s| return s.description.name,
        }
    }

    pub fn getPath(c: *const Collection) []const u8 {
        switch (c.*) {
            .Tasklist => |s| return s.info.path,
            inline else => |s| return s.description.path,
        }
    }

    pub fn sort(_: *const Collection, items: []Item, how: Ordering) void {
        switch (how) {
            .Modified => std.sort.insertion(Item, items, {}, Item.sortModified),
            .Created => std.sort.insertion(Item, items, {}, Item.sortCreated),
            .Due => std.sort.insertion(Item, items, {}, Item.sortDue),
        }
    }

    pub fn writeChanges(
        c: *Collection,
        alloc: std.mem.Allocator,
    ) !void {
        switch (c.*) {
            .Journal => |*j| {
                for (j.description.infos) |*day| {
                    var entries = j.content.get(day.name) orelse continue;

                    // update last modified
                    day.modified = time(Topology.Entry, entries, "modified", .Max);
                    // stringify
                    const string = try Topology.stringifyEntries(alloc, entries);
                    defer alloc.free(string);

                    try j.fs.overwrite(day.path, string);
                }
            },
            .Tasklist => |t| {
                var tasks = t.tasks orelse return;
                // update last modified
                t.info.modified = time(Tasklist.Task, tasks, "modified", .Max);
                // stringify
                const string = try Topology.stringifyTasks(alloc, tasks);
                defer alloc.free(string);

                try t.fs.overwrite(t.info.path, string);
            },
            else => unreachable,
        }
    }
};

fn time(
    comptime T: type,
    items: []const T,
    comptime field: []const u8,
    comptime cmp: enum { Min, Max },
) u64 {
    std.debug.assert(items.len > 0);

    var val: u64 = @field(items[0], field);
    for (items[1..]) |item| {
        const t = @field(item, field);
        val = switch (cmp) {
            .Min => @min(val, t),
            .Max => @max(val, t),
        };
    }

    return val;
}
