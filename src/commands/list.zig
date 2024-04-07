const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");
const colors = @import("../colors.zig");

const commands = @import("../commands.zig");
const Journal = @import("../topology/Journal.zig");
const Tasklist = @import("../topology/Tasklist.zig");
const Root = @import("../topology/Root.zig");

const FormatPrinter = @import("../printers.zig").FormatPrinter;
const TaskPrinter = @import("../printers.zig").TaskPrinter;

const Self = @This();

pub const alias = [_][]const u8{"ls"};

pub const short_help = "List collections and other information in various ways.";
pub const long_help = short_help;

const MUTUAL_FIELDS: []const []const u8 = &.{
    "sort",
};

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "--sort how",
        .help = "How to sort the item lists. Possible values are 'alphabetical', 'modified' or 'created'. Defaults to created.",
    },
    .{
        .arg = "what",
        .help = "Can be 'tags', 'compilers', or when directory is selected, can be used to subselect hiearchies",
    },
    .{
        .arg = "--directory name",
        .help = "Name of the directory to list.",
        .completion = "{compadd $(nkt completion list --collection directory)}",
    },
    .{
        .arg = "--journal name",
        .help = "Name of the journal to list.",
        .completion = "{compadd $(nkt completion list --collection journal)}",
    },
    .{
        .arg = "--tasklist name",
        .help = "Name of the tasklist to list.",
        .completion = "{compadd $(nkt completion list --collection tasklist)}",
    },
    .{
        .arg = "--hash",
        .help = "Display the full hashes instead of abbreviations.",
    },
    .{
        .arg = "--done",
        .help = "If a tasklist is selected, enables listing tasks marked as 'done'",
    },
    .{
        .arg = "--archived",
        .help = "If a tasklist is selected, enables listing tasks marked as 'archived'",
    },
});

const ListSelection = union(enum) {
    Directory: struct {
        note: ?[]const u8,
        name: []const u8,
    },
    Journal: struct {
        name: []const u8,
    },
    Tasklist: struct {
        name: []const u8,
        done: bool,
        hash: bool,
        archived: bool,
    },
    Collections: void,
    Tags: void,
    Compilers: void,
};

const SortingMethods = enum {
    alphabetical,
    modified,
    created,
};

selection: ListSelection,
sort: SortingMethods,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    return .{
        .selection = try processArguments(args),
        .sort = std.meta.stringToEnum(
            SortingMethods,
            args.sort orelse "created",
        ) orelse {
            try cli.throwError(
                error.UnknownSort,
                "Sorting method '{s}' is unknown",
                .{args.sort.?},
            );
            unreachable;
        },
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();

    switch (self.selection) {
        .Collections => try listCollections(root, writer, opts),
        .Tags => try listTags(allocator, root, writer, opts),
        .Compilers => try listCompilers(allocator, root, writer, opts),
        .Directory => |i| try self.listDirectory(i, root, writer, opts),
        .Journal => |i| try listJournal(i, root, writer, opts),
        .Tasklist => |i| try listTasklist(allocator, i, root, writer, opts),
    }
}

fn processArguments(args: arguments.Parsed) !ListSelection {
    var count: usize = 0;
    if (args.journal != null) count += 1;
    if (args.directory != null) count += 1;
    if (args.tasklist != null) count += 1;
    if (count > 1) {
        try cli.throwError(
            error.AmbiguousSelection,
            "Can only list a single collection.",
            .{},
        );
        unreachable;
    }

    if (args.journal) |journal| {
        // make sure none of the incompatible fields are selected
        try utils.ensureOnly(
            arguments.Parsed,
            args,
            MUTUAL_FIELDS,
            "journal",
        );
        return .{ .Journal = .{ .name = journal } };
    }
    if (args.tasklist) |tasklist| {
        // make sure none of the incompatible fields are selected
        try utils.ensureOnly(
            arguments.Parsed,
            args,
            (MUTUAL_FIELDS ++ [_][]const u8{ "done", "archived", "hash" }),
            "tasklist",
        );
        return .{ .Tasklist = .{
            .name = tasklist,
            .done = args.done,
            .hash = args.hash,
            .archived = args.archived,
        } };
    }
    if (args.directory) |directory| {
        // make sure none of the incompatible fields are selected
        try utils.ensureOnly(
            arguments.Parsed,
            args,
            (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
            "directory",
        );
        return .{ .Directory = .{
            .name = directory,
            .note = args.what,
        } };
    }

    if (args.what) |what| {
        if (std.mem.eql(u8, what, "tags")) {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                "tags",
            );
            return .{ .Tags = {} };
        } else if (std.mem.eql(u8, what, "compilers")) {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                "compilers",
            );
            return .{ .Compilers = {} };
        }
        try cli.throwError(
            cli.CLIErrors.BadArgument,
            "Unknown selection: '{s}'",
            .{what},
        );
        unreachable;
    }

    try utils.ensureOnly(
        arguments.Parsed,
        args,
        MUTUAL_FIELDS,
        "collections",
    );

    return .{ .Collections = {} };
}

fn listCollections(
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try writer.writeAll("Directories:\n");
    for (root.info.directories) |d| {
        const dir = (try root.getDirectory(d.name)).?;
        const n = dir.info.notes.len;
        try writer.print(
            "- {s: <15} ({d} {s})\n",
            .{ d.name, n, if (n == 1) "note" else "notes" },
        );
    }
    try writer.writeAll("\nJournals:\n");
    for (root.info.journals) |j| {
        const journal = (try root.getJournal(j.name)).?;
        const n = journal.info.days.len;
        try writer.print(
            "- {s: <15} ({d} {s})\n",
            .{ j.name, n, if (n == 1) "day" else "days" },
        );
    }
    try writer.writeAll("\nTasklists:\n");
    for (root.info.tasklists) |t| {
        const tasklist = (try root.getTasklist(t.name)).?;
        const n = tasklist.info.tasks.len;
        try writer.print(
            "- {s: <15} ({d} {s})\n",
            .{ t.name, n, if (n == 1) "task" else "tasks" },
        );
    }
    try writer.writeAll("\n");
    _ = opts;
}

fn listCompilers(
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    var printer = FormatPrinter.init(allocator, .{
        .pretty = !opts.piped,
    });
    defer printer.deinit();

    for (root.info.text_compilers) |cmp| {
        try printer.addText("Compiler:         ", .{});
        try printer.addFmtText("{s}\n", .{cmp.name}, .{ .fmt = colors.YELLOW.fixed() });
        try printer.addText(" - Extensions:    ", .{});
        for (cmp.extensions) |ext| {
            try printer.addFmtText("{s} ", .{ext}, .{ .fmt = colors.CYAN.fixed() });
        }
        try printer.addText("\n\n", .{});
    }

    try printer.drain(writer);
}

fn listTags(
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    var tdl = try root.getTagDescriptorList();
    tdl.sort(.Alphabetical);

    var printer = FormatPrinter.init(allocator, .{
        .pretty = !opts.piped,
        .tag_descriptors = tdl.tags,
    });
    defer printer.deinit();

    try printer.addText("Tags:\n", .{});
    for (tdl.tags) |info| {
        try printer.addFmtText(" - @{s}\n", .{info.name}, .{});
    }
    try printer.addText("\n", .{});

    try printer.drain(writer);
}

fn listJournal(
    j: utils.TagType(ListSelection, "Journal"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try writer.writeAll("TODO: not implemented yet\n");
    _ = j;
    _ = root;
    _ = opts;
}

fn listTasklist(
    allocator: std.mem.Allocator,
    tl: utils.TagType(ListSelection, "Tasklist"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const maybe_tl = try root.getTasklist(tl.name);
    var tasklist = maybe_tl orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory named '{s}'",
            .{tl.name},
        );
        unreachable;
    };

    // TODO: apply sorting: get user selection
    const index_map = try tasklist.makeIndexMap();

    try listTasks(
        allocator,
        tl,
        tasklist.info.tasks,
        index_map,
        root,
        writer,
        opts,
    );
}

fn listTasks(
    allocator: std.mem.Allocator,
    tl: utils.TagType(ListSelection, "Tasklist"),
    tasks: []const Tasklist.Task,
    index_map: []const ?usize,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const tag_descriptors = try root.getTagDescriptorList();

    var printer = TaskPrinter.init(
        allocator,
        .{
            .pretty = !opts.piped,
            .tag_descriptors = tag_descriptors.tags,
            .full_hash = tl.hash,
            .tz = opts.tz,
        },
    );
    defer printer.deinit();

    for (tasks, index_map) |task, t_index| {
        if (!tl.done and task.isDone()) {
            continue;
        }
        if (!tl.archived and task.isArchived()) {
            continue;
        }
        try printer.add(task, t_index);
    }

    try printer.drain(writer, false);
}

fn listDirectory(
    self: *Self,
    d: utils.TagType(ListSelection, "Directory"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const maybe_dir = try root.getDirectory(d.name);
    const dir = maybe_dir orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory named '{s}'",
            .{d.name},
        );
        unreachable;
    };

    if (dir.info.notes.len == 0) {
        try writer.writeAll(" -- Directory Empty -- \n");
    }

    // TODO: sorting
    const pad = b: {
        var max: usize = 0;
        for (dir.info.notes) |n| {
            max = @max(max, n.name.len);
        }
        break :b max;
    };

    switch (self.sort) {
        .alphabetical => {
            std.sort.insertion(
                Root.Directory.Note,
                dir.info.notes,
                {},
                Root.Directory.Note.sortAlphabetical,
            );
        },
        .created => {
            std.sort.insertion(
                Root.Directory.Note,
                dir.info.notes,
                {},
                Root.Directory.Note.sortCreated,
            );
        },
        .modified => {
            std.sort.insertion(
                Root.Directory.Note,
                dir.info.notes,
                {},
                Root.Directory.Note.sortModified,
            );
        },
    }

    for (dir.info.notes) |note| {
        try writer.writeAll(note.name);
        try writer.writeByteNTimes(' ', pad - note.name.len);
        try writer.print(" - {s}", .{try note.modified.formatDateTime()});
        try writer.writeAll("\n");
    }
    _ = opts;
}
