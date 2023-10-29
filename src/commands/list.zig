const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const TaskPrinter = @import("../TaskPrinter.zig");

const Self = @This();

pub const ListError = error{CannotListJournal};

pub const alias = [_][]const u8{"ls"};

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list
    \\     <what>                list journals, directories, tasklists, or notes
    \\                             with a `directory` to list. this option may
    \\                             also be `all` to list everything (default: all)
    \\     -n/--limit int        maximum number of entries to list (default: 25)
    \\     --all                 list all entries (ignores `--limit`)
    \\     --modified            sort by last modified (default)
    \\     --created             sort by date created
    \\     --pretty/--nopretty   pretty format the output, or don't (default
    \\                           is to pretty format)
    \\
    \\When the `<what>` is a task list, the additional options are
    \\     --due                 list in order of when something is due (default)
    \\     --importance          list in order of importance
    \\     --done                list also those tasks marked as done
    \\
;

selection: []const u8 = "",
ordering: State.Ordering = .Modified,
number: usize = 25,
all: bool = false,
pretty: bool = true,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{};

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                self.all = true;
            } else if (arg.is(null, "modified")) {
                self.ordering = .Modified;
            } else if (arg.is(null, "created")) {
                self.ordering = .Created;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (self.selection.len == 0) {
                self.selection = arg.string;
            } else return cli.CLIErrors.TooManyArguments;
        }
    }

    if (self.selection.len == 0) self.selection = "all";

    return self;
}

fn listDirectory(
    self: *Self,
    alloc: std.mem.Allocator,
    directory: *State.Directory,
    writer: anytype,
) !void {
    var notelist = try directory.getChildList(alloc);
    defer notelist.deinit();

    notelist.sortBy(self.ordering);

    const collection_name = directory.collectionName();

    switch (self.ordering) {
        .Modified => try writer.print(
            "Directory '{s}' ordered by last modified:\n",
            .{collection_name},
        ),
        .Created => try writer.print(
            "Directory '{s}' ordered by date created:\n",
            .{collection_name},
        ),
    }

    const is_diary = std.mem.eql(u8, "diary", collection_name);
    for (notelist.items) |note| {
        if (is_diary) {
            try writer.print("{s}\n", .{note.getName()});
        } else {
            const date = switch (self.ordering) {
                .Modified => utils.dateFromMs(note.info.modified),
                .Created => utils.dateFromMs(note.info.created),
            };
            const date_string = try utils.formatDateBuf(date);
            try writer.print("{s} - {s}\n", .{ date_string, note.getName() });
        }
    }
}

pub fn listNames(
    cnames: State.CollectionNameList,
    what: State.CollectionType,
    writer: anytype,
    opts: struct { oneline: bool = false },
) !void {
    if (!opts.oneline) {
        switch (what) {
            .Directory => try writer.print("Directories list:\n", .{}),
            .Journal => try writer.print("Journals list:\n", .{}),
            .TaskList => try writer.print("Tasklist list:\n", .{}),
            .DirectoryWithJournal => unreachable,
        }
    }

    for (cnames.items) |name| {
        if (name.collection != what) continue;

        if (opts.oneline) {
            try writer.print("{s} ", .{name.name});
        } else {
            try writer.print(" - {s}\n", .{name.name});
        }
    }
}

fn listJournal(
    self: *Self,
    alloc: std.mem.Allocator,
    journal: *State.Journal,
    writer: anytype,
) !void {
    var entrylist = try journal.getChildList(alloc);
    defer entrylist.deinit();

    entrylist.sortBy(self.ordering);

    switch (self.ordering) {
        .Modified => try writer.print(
            "Journal '{s}' ordered by last modified:\n",
            .{journal.collectionName()},
        ),
        .Created => try writer.print(
            "Journal '{s}' ordered by date created:\n",
            .{journal.collectionName()},
        ),
    }

    for (entrylist.items) |entry| {
        try writer.print("{s}\n", .{entry.info.name});
    }
}

fn listTasks(
    self: *Self,
    alloc: std.mem.Allocator,
    tasklist: *State.TaskList,
    writer: anytype,
) !void {
    const Task = State.TaskList.Child.Item;
    _ = self;

    var tasks = try tasklist.getItemList(alloc);
    defer tasks.deinit();

    std.sort.insertion(Task, tasks.items, {}, Task.sortDue);
    std.mem.reverse(Task, tasks.items);

    var printer = TaskPrinter.init(alloc);
    defer printer.deinit();

    for (tasks.items) |task| {
        try printer.add(task);
    }

    try printer.drain(writer);
}

fn is(s: []const u8, other: []const u8) bool {
    return std.mem.eql(u8, s, other);
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    if (is(self.selection, "all")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try listNames(cnames, .Directory, out_writer, .{});
        try listNames(cnames, .Journal, out_writer, .{});
        try listNames(cnames, .TaskList, out_writer, .{});
    } else if (is(self.selection, "directories") or is(self.selection, "dirs")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try listNames(cnames, .Directory, out_writer, .{});
    } else if (is(self.selection, "journals") or is(self.selection, "jrnl")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try listNames(cnames, .Journal, out_writer, .{});
    } else if (is(self.selection, "tasklists") or is(self.selection, "tasks")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try listNames(cnames, .TaskList, out_writer, .{});
    } else {
        var collection = state.getCollection(self.selection) orelse
            return State.Collection.Errors.NoSuchCollection;
        switch (collection) {
            .Directory => |d| {
                try self.listDirectory(state.allocator, d, out_writer);
            },
            .Journal => |j| {
                try self.listJournal(state.allocator, j, out_writer);
            },
            .DirectoryWithJournal => |dj| {
                try self.listDirectory(state.allocator, dj.directory, out_writer);
                try self.listJournal(state.allocator, dj.journal, out_writer);
            },
            .TaskList => |tl| {
                try self.listTasks(state.allocator, tl, out_writer);
            },
        }
    }
}
