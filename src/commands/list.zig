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
    \\     <what>                list the notes in a directory, journal, or tasks. this option may
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
ordering: ?State.Ordering = null,
number: usize = 25,
all: bool = false,
pretty: ?bool = null,
done: bool = false,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
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
            } else if (arg.is(null, "done")) {
                self.done = true;
            } else if (arg.is(null, "created")) {
                self.ordering = .Created;
            } else if (arg.is(null, "nopretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = false;
            } else if (arg.is(null, "pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = true;
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

    // don't pretty format by default if not tty
    self.pretty = self.pretty orelse !opts.piped;

    return self;
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
            .Tasklist => try writer.print("Tasklist list:\n", .{}),
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

const Task = @import("../collections/Topology.zig").Task;
fn listTasks(
    self: *Self,
    alloc: std.mem.Allocator,
    c: *State.Collection,
    writer: anytype,
) !void {
    // need to read tasklist from file
    try c.readAll();
    var tasks = try c.getAll(alloc);
    defer alloc.free(tasks);

    c.sort(tasks, self.ordering orelse .Due);
    std.mem.reverse(State.Item, tasks);

    var printer = TaskPrinter.init(alloc, self.pretty.?);
    defer printer.deinit();

    var lookup = try c.Tasklist.invertIndexMap(alloc);
    defer lookup.deinit();

    for (tasks) |task| {
        if (!self.done and task.Task.task.completed != null) {
            continue;
        }
        const index = lookup.get(task.Task.task.title);
        try printer.add(task.Task.task.*, index);
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
    var cnames = try state.getCollectionNames(state.allocator);
    defer cnames.deinit();

    if (is(self.selection, "all")) {
        try listNames(cnames, .Directory, out_writer, .{});
        try listNames(cnames, .Journal, out_writer, .{});
        try listNames(cnames, .Tasklist, out_writer, .{});
    } else if (is(self.selection, "dir") or is(self.selection, "directories")) {
        try listNames(cnames, .Directory, out_writer, .{});
    } else if (is(self.selection, "journals")) {
        try listNames(cnames, .Journal, out_writer, .{});
    } else if (is(self.selection, "tasklists")) {
        try listNames(cnames, .Tasklist, out_writer, .{});
    } else {
        var collection: State.MaybeCollection = state.getCollectionByName(self.selection) orelse
            return State.Error.NoSuchCollection;

        if (collection.directory) |c| {
            try out_writer.print("Notes in directory: '{s}':\n", .{c.getName()});
            try self.listCollection(
                state.allocator,
                c,
                self.ordering orelse .Modified,
                out_writer,
            );
        }
        if (collection.journal) |c| {
            try out_writer.print("Entries in journal: '{s}':\n", .{c.getName()});
            try self.listCollection(
                state.allocator,
                c,
                self.ordering orelse .Modified,
                out_writer,
            );
        }
        if (collection.tasklist) |c| {
            try out_writer.print("Tasks in tasklist: '{s}':\n", .{c.getName()});
            try self.listTasks(state.allocator, c, out_writer);
        }
    }
}

fn listCollection(
    _: *const Self,
    alloc: std.mem.Allocator,
    c: *State.Collection,
    order: State.Ordering,
    writer: anytype,
) !void {
    var items = try c.getAll(alloc);
    defer alloc.free(items);

    c.sort(items, order);

    for (items) |item| {
        try writer.print(" - {s}\n", .{item.getName()});
    }
}
