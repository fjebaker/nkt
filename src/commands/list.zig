const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const tags = @import("../tags.zig");

const State = @import("../State.zig");
const TaskPrinter = @import("../TaskPrinter.zig");
const FormatPrinter = @import("../FormatPrinter.zig");

const Self = @This();

pub const ListError = error{CannotListJournal};

pub const alias = [_][]const u8{"ls"};

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list
    \\     <what>                list the notes in a directory, journal, or tasks. this option may
    \\                             also be `all` to list everything. To list all tasklists use
    \\                             `tasks` (default: all)
    \\     -n/--limit int        maximum number of entries to list (default: 25)
    \\     --all                 list all entries (ignores `--limit`)
    \\     --modified            sort by last modified (default)
    \\     --created             sort by date created
    \\     --alphabetical        sort by date created
    \\     --pretty/--nopretty   pretty format the output, or don't (default
    \\                           is to pretty format)
    \\
    \\When the `<what>` is a task list, the additional options are
    \\     --due                 list in order of when something is due (default)
    \\     --importance          list in order of importance
    \\     --done                list also those tasks marked as done
    \\     --archived            list also archived tasks
    \\     --details             also print details of the tasks
    \\
;

selection: []const u8 = "",
ordering: ?State.Ordering = null,
number: usize = 25,
all: bool = false,
pretty: ?bool = null,
done: bool = false,
archived: bool = false,
details: bool = false,

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
            } else if (arg.is(null, "alphabetical")) {
                self.ordering = .Alphabetical;
            } else if (arg.is(null, "done")) {
                self.done = true;
            } else if (arg.is(null, "archived")) {
                self.archived = true;
            } else if (arg.is(null, "created")) {
                self.ordering = .Created;
            } else if (arg.is(null, "nopretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = false;
            } else if (arg.is(null, "pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = true;
            } else if (arg.is(null, "details")) {
                self.details = true;
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
            .Directory => try writer.print("Directories:\n", .{}),
            .Journal => try writer.print("Journals:\n", .{}),
            .Tasklist => try writer.print("Tasklists:\n", .{}),
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

    _ = try writer.writeAll("\n");
}

const Task = @import("../collections/Topology.zig").Task;
fn listTasks(
    self: *Self,
    alloc: std.mem.Allocator,
    state: *State,
    c: *State.Collection,
    writer: anytype,
) !void {
    // need to read tasklist from file
    try c.readAll();
    const tasks = try c.getAll(alloc);
    defer alloc.free(tasks);

    c.sort(tasks, self.ordering orelse .Due);
    std.mem.reverse(State.Item, tasks);

    var printer = TaskPrinter.init(alloc, self.pretty.?);
    defer printer.deinit();

    printer.taginfo = state.getTagInfo();

    var lookup = try c.Tasklist.invertIndexMap(alloc);
    defer lookup.deinit();

    for (tasks) |task| {
        if (!self.done and task.Task.isDone()) {
            continue;
        }
        if (!self.archived and task.Task.isArchived()) {
            continue;
        }
        const index = lookup.get(task.Task.task.title);
        try printer.add(task.Task.task.*, index);
    }

    try printer.drain(writer, state.getTagInfo(), self.details);
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
        try listChains(try state.getChains(), out_writer);
    } else if (is(self.selection, "dir") or is(self.selection, "directories")) {
        try listNames(cnames, .Directory, out_writer, .{});
    } else if (is(self.selection, "journals")) {
        try listNames(cnames, .Journal, out_writer, .{});
    } else if (is(self.selection, "tasklists")) {
        try listNames(cnames, .Tasklist, out_writer, .{});
    } else if (is(self.selection, "tasks")) {
        const tls = state.getTasklists();
        for (tls) |*c| {
            try out_writer.print("Tasks in tasklist '{s}':\n", .{c.getName()});
            try self.listTasks(state.allocator, state, c, out_writer);
        }
    } else if (is(self.selection, "tags")) {
        try self.listTags(state.allocator, state.getTagInfo(), out_writer);
    } else if (is(self.selection, "chains")) {
        try listChains(try state.getChains(), out_writer);
    } else {
        const collection: State.MaybeCollection = state.getCollectionByName(self.selection) orelse
            return State.Error.NoSuchCollection;

        if (collection.directory) |c| {
            try out_writer.print("Notes in directory '{s}':\n", .{c.getName()});
            try self.listCollection(
                state.allocator,
                c,
                self.ordering orelse .Alphabetical,
                out_writer,
            );
        }
        if (collection.journal) |c| {
            try out_writer.print("Entries in journal '{s}':\n", .{c.getName()});
            try self.listCollection(
                state.allocator,
                c,
                self.ordering orelse .Modified,
                out_writer,
            );
        }
        if (collection.tasklist) |c| {
            try out_writer.print("Tasks in tasklist '{s}':\n", .{c.getName()});
            try self.listTasks(state.allocator, state, c, out_writer);
        }
    }
}

fn listChains(chains: []State.Chain, writer: anytype) !void {
    try writer.writeAll("Chains:\n");
    for (chains) |chain| {
        try writer.print(" - {s}\n", .{chain.name});
    }

    try writer.writeAll("\n");
}

fn listCollection(
    _: *const Self,
    alloc: std.mem.Allocator,
    c: *State.Collection,
    order: State.Ordering,
    writer: anytype,
) !void {
    if (c.* == .Tasklist) unreachable;

    const items = try c.getAll(alloc);
    defer alloc.free(items);

    c.sort(items, order);
    const padding = p: {
        var longest: usize = 0;
        for (items) |item| {
            longest = @max(longest, item.getName().len);
        }
        break :p longest;
    };

    for (items) |item| {
        const name = item.getName();
        if (c.* == .Directory) {
            const size = c.Directory.fs.dir.statFile(item.getPath()) catch |err| {
                std.debug.print("ERR: {s}\n", .{item.getPath()});
                return err;
            };
            const date = utils.dateFromMs(item.Note.note.modified);
            const fmt_date = try utils.formatDateTimeBuf(date);

            try writer.print(" - {d: >7}  {s}", .{ size.size, name });
            try writer.writeByteNTimes(' ', padding - name.len + 2);
            try writer.print("{s}\n", .{fmt_date});
        } else {
            try writer.print(" - {s}\n", .{item.getName()});
        }
    }
}

fn listTags(
    self: *const Self,
    alloc: std.mem.Allocator,
    infos: []const tags.TagInfo,
    out_writer: anytype,
) !void {
    var printer = FormatPrinter.init(alloc, .{ .pretty = self.pretty.? });
    defer printer.deinit();

    printer.tag_infos = infos;

    try printer.addText("Tags:\n", .{});
    for (infos) |info| {
        try printer.addFmtText(" - @{s}\n", .{info.name}, .{});
    }
    try printer.addText("\n", .{});

    try printer.drain(out_writer);
}
