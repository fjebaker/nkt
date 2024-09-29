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
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const Item = @import("../abstractions.zig").Item;

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
        .help = "How to sort the item lists. Possible values are 'alpha[betical]', 'modified' or 'created'. ",
        .default = "alphabetical",
    },
    .{
        .arg = "what",
        .help = "Can be 'tags', 'compilers', a specific @tag, or the name of a collection.",
        .completion = "{compadd tags compilers $(nkt completion list --all-collections)}",
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
    NamedSelection: []const u8,
    Collections: void,
    Tags: void,
    Stacks: void,
    Tag: []const u8,
    Compilers: void,
};

args: arguments.Parsed,
selection: ListSelection,
sort: Tasklist.SortingOptions,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    const sort_method = std.meta.stringToEnum(
        Tasklist.SortingOptions.Method,
        args.sort,
    ) orelse {
        return cli.throwError(
            error.UnknownSort,
            "Sorting method '{s}' is unknown",
            .{args.sort},
        );
    };
    return .{
        .args = args,
        .selection = try processArguments(args),
        .sort = .{ .how = sort_method },
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
        .Tasklist => |i| try listTasklist(allocator, i, root, writer, self.sort, opts),
        .Stacks => |i| try listStacks(allocator, i, root, writer, opts),
        .Tag => |t| try listTagged(allocator, t, root, writer, opts),
        .NamedSelection => |name| {
            const collection_selector = selections.Selection{
                .collection_name = name,
                .collection_provided = true,
            };

            const col = (try collection_selector.resolveReportError(root)).Collection;
            switch (col) {
                .directory => {
                    const x = try processDirectoryArgs(
                        name,
                        self.args,
                        &.{"what"},
                    );
                    try self.listDirectory(
                        x.Directory,
                        root,
                        writer,
                        opts,
                    );
                },
                .journal => {
                    const x = try processJournalArgs(
                        name,
                        self.args,
                        &.{"what"},
                    );
                    try listJournal(
                        x.Journal,
                        root,
                        writer,
                        opts,
                    );
                },
                .tasklist => {
                    const x = try processTasklistArgs(
                        name,
                        self.args,
                        &.{"what"},
                    );
                    try listTasklist(
                        allocator,
                        x.Tasklist,
                        root,
                        writer,
                        self.sort,
                        opts,
                    );
                },
            }
        },
    }
}

fn processTasklistArgs(
    name: []const u8,
    args: arguments.Parsed,
    comptime extra_fields: []const []const u8,
) !ListSelection {
    // make sure none of the incompatible fields are selected
    try utils.ensureOnly(
        arguments.Parsed,
        args,
        (MUTUAL_FIELDS ++ [_][]const u8{ "done", "archived", "hash" } ++ extra_fields),
        "tasklist",
    );
    return .{ .Tasklist = .{
        .name = name,
        .done = args.done,
        .hash = args.hash,
        .archived = args.archived,
    } };
}
fn processDirectoryArgs(
    name: []const u8,
    args: arguments.Parsed,
    comptime extra_fields: []const []const u8,
) !ListSelection {
    // make sure none of the incompatible fields are selected
    try utils.ensureOnly(
        arguments.Parsed,
        args,
        (MUTUAL_FIELDS ++ [_][]const u8{"what"} ++ extra_fields),
        "directory",
    );
    return .{ .Directory = .{
        .name = name,
        .note = args.what,
    } };
}
fn processJournalArgs(
    name: []const u8,
    args: arguments.Parsed,
    comptime extra_fields: []const []const u8,
) !ListSelection {
    // make sure none of the incompatible fields are selected
    try utils.ensureOnly(
        arguments.Parsed,
        args,
        MUTUAL_FIELDS ++ extra_fields,
        "journal",
    );
    return .{ .Journal = .{ .name = name } };
}

fn processArguments(args: arguments.Parsed) !ListSelection {
    var count: usize = 0;
    if (args.journal != null) count += 1;
    if (args.directory != null) count += 1;
    if (args.tasklist != null) count += 1;
    if (count > 1) {
        return cli.throwError(
            error.AmbiguousSelection,
            "Can only list a single collection.",
            .{},
        );
    }

    if (args.journal) |journal| {
        return try processJournalArgs(journal, args, &.{});
    }
    if (args.tasklist) |tasklist| {
        return try processTasklistArgs(tasklist, args, &.{});
    }
    if (args.directory) |directory| {
        return try processDirectoryArgs(directory, args, &.{});
    }

    if (args.what) |what| {
        if (std.mem.eql(u8, what, "tags")) {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                what,
            );
            return .{ .Tags = {} };
        } else if (std.mem.eql(u8, what, "stacks")) {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                what,
            );
            return .{ .Stacks = {} };
        } else if (std.mem.eql(u8, what, "compilers")) {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                what,
            );
            return .{ .Compilers = {} };
        } else if (what[0] == '@') {
            try utils.ensureOnly(
                arguments.Parsed,
                args,
                (MUTUAL_FIELDS ++ [_][]const u8{"what"}),
                what,
            );
            return .{ .Tag = what };
        }

        // make sure none of the incompatible fields are selected
        return .{ .NamedSelection = what };
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
        const n = dir.getInfo().notes.len;
        try writer.print(
            "- {s: <15} ({d} {s})\n",
            .{ d.name, n, if (n == 1) "note" else "notes" },
        );
    }
    try writer.writeAll("\nJournals:\n");
    for (root.info.journals) |j| {
        const journal = (try root.getJournal(j.name)).?;
        const n = journal.getInfo().days.len;
        try writer.print(
            "- {s: <15} ({d} {s})\n",
            .{ j.name, n, if (n == 1) "day" else "days" },
        );
    }
    try writer.writeAll("\nTasklists:\n");
    for (root.info.tasklists) |t| {
        const tasklist = (try root.getTasklist(t.name)).?;
        const n = tasklist.getInfo().tasks.len;
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
        try printer.addFmtText("{s}\n", .{cmp.name}, .{ .fmt = colors.YELLOW });
        try printer.addText(" - Extensions:    ", .{});
        for (cmp.extensions) |ext| {
            try printer.addFmtText("{s} ", .{ext}, .{ .fmt = colors.CYAN });
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

fn listStacks(
    allocator: std.mem.Allocator,
    tl: utils.TagType(ListSelection, "Stacks"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    _ = allocator;
    _ = tl;
    _ = opts;
    const sl = try root.getStackList();
    if (sl.stacks.len == 0) {
        try writer.writeAll("No stacks. Use `new stack NAME` to add a new stack\n");
        return;
    }
    for (sl.stacks) |stack| {
        try writer.print("{s}: {d} items\n", .{ stack.name, stack.items.len });
    }
}

fn listTasklist(
    allocator: std.mem.Allocator,
    tl: utils.TagType(ListSelection, "Tasklist"),
    root: *Root,
    writer: anytype,
    sopts: Tasklist.SortingOptions,
    opts: commands.Options,
) !void {
    const maybe_tl = try root.getTasklist(tl.name);
    var tasklist = maybe_tl orelse {
        return cli.throwError(
            Root.Error.NoSuchCollection,
            "No tasklist named '{s}'",
            .{tl.name},
        );
    };

    // TODO: apply sorting: get user selection
    const index_map = try tasklist.makeIndexMap();

    try listTasks(
        allocator,
        tl,
        tasklist.getInfo().tasks,
        index_map,
        root,
        writer,
        sopts,
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
    sopts: Tasklist.SortingOptions,
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

    // work out the ordering by how they are to be sorted
    const ordering = try sortTaskOrder(allocator, tasks, sopts);
    defer allocator.free(ordering);

    for (ordering) |i| {
        const task = tasks[i];
        const t_index = index_map[i];
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

fn sortTaskOrder(
    allocator: std.mem.Allocator,
    tasks: []const Tasklist.Task,
    sopts: Tasklist.SortingOptions,
) ![]const usize {
    const order = try allocator.alloc(usize, tasks.len);
    errdefer allocator.free(order);
    for (0.., order) |i, *o| o.* = i;

    const SortContext = struct {
        ts: []const Tasklist.Task,
        opts: Tasklist.SortingOptions,
        pub fn sorter(self: @This(), lhs: usize, rhs: usize) bool {
            return Tasklist.taskSorter(self.opts, self.ts[lhs], self.ts[rhs]);
        }
    };

    const ctx = SortContext{
        .opts = sopts,
        .ts = tasks,
    };

    std.sort.heap(usize, order, ctx, SortContext.sorter);
    std.mem.reverse(usize, order);
    return order;
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
        return cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory named '{s}'",
            .{d.name},
        );
    };

    const dir_info = dir.getInfo();

    if (dir_info.notes.len == 0) {
        try writer.writeAll(" -- Directory Empty -- \n");
    }

    const pad = b: {
        var max: usize = 0;
        for (dir_info.notes) |n| {
            max = @max(max, n.name.len);
        }
        break :b max;
    };

    switch (self.sort.how) {
        .canonical, .alpha, .alphabetical => {
            std.sort.insertion(
                Root.Directory.Note,
                dir_info.notes,
                {},
                Root.Directory.Note.sortAlphabetical,
            );
        },
        .created => {
            std.sort.insertion(
                Root.Directory.Note,
                dir_info.notes,
                {},
                Root.Directory.Note.sortCreated,
            );
        },
        .modified => {
            std.sort.insertion(
                Root.Directory.Note,
                dir_info.notes,
                {},
                Root.Directory.Note.sortModified,
            );
        },
    }

    for (dir_info.notes) |note| {
        try writer.writeAll(note.name);
        try writer.writeByteNTimes(' ', pad - note.name.len);
        try writer.print(" - {s}", .{try note.modified.formatDateTime()});
        try writer.writeAll("\n");
    }
    _ = opts;
}

const TaggedItems = struct {
    items: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator) TaggedItems {
        return .{
            .items = std.ArrayList(Item).init(allocator),
        };
    }

    pub fn deinit(self: *TaggedItems) void {
        self.items.deinit();
        self.* = undefined;
    }
};

fn listTagged(
    allocator: std.mem.Allocator,
    t: []const u8,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const now = time.Time.now();
    const st = try tags.parseInlineTags(allocator, t, now);
    defer allocator.free(st);

    var tl = try root.getTagDescriptorList();
    if (tl.findInvalidTags(st)) |_t| {
        return cli.throwError(
            error.InvalidTag,
            "'{s}' is not a valid tag",
            .{_t.name},
        );
    }

    var tagged_items = TaggedItems.init(allocator);
    defer tagged_items.deinit();

    for (root.getAllDescriptor(.CollectionDirectory)) |d| {
        const dir = (try root.getDirectory(d.name)).?;
        for (dir.getInfo().notes) |note| {
            if (tags.hasUnion(note.tags, st)) {
                try tagged_items.items.append(
                    .{ .Note = .{ .directory = dir, .note = note } },
                );
            }
        }
    }

    for (root.getAllDescriptor(.CollectionTasklist)) |d| {
        const tlist = (try root.getTasklist(d.name)).?;
        for (tlist.getInfo().tasks) |task| {
            if (tags.hasUnion(task.tags, st)) {
                try tagged_items.items.append(
                    .{ .Task = .{ .tasklist = tlist, .task = task } },
                );
            }
        }
    }

    for (root.getAllDescriptor(.CollectionJournal)) |d| {
        var journal = (try root.getJournal(d.name)).?;
        for (journal.getInfo().days) |day| {
            const entries = try journal.getEntries(day);
            for (entries) |e| {
                if (tags.hasUnion(e.tags, st)) {
                    try tagged_items.items.append(
                        .{ .Entry = .{ .journal = journal, .day = day, .entry = e } },
                    );
                }
            }
        }
    }

    // sort by last modified
    std.sort.heap(Item, tagged_items.items.items, {}, Item.modifiedDescending);

    try printItems(
        allocator,
        writer,
        tagged_items.items.items,
        (try root.getTagDescriptorList()).tags,
        opts,
    );
}

pub fn printItems(
    allocator: std.mem.Allocator,
    writer: anytype,
    items: []const Item,
    tag_descriptors: []const tags.Tag.Descriptor,
    opts: commands.Options,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var printer = FormatPrinter.init(allocator, .{
        .pretty = !opts.piped,
        .tag_descriptors = tag_descriptors,
    });
    defer printer.deinit();

    for (items) |nd| {
        const name = try nd.getName(alloc);
        switch (nd) {
            .Entry => {
                try printer.addFmtText(
                    "journal:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.JOURNAL },
                );
                try printer.addFmtText(
                    " {s}",
                    .{name},
                    .{},
                );
            },
            .Note => {
                try printer.addFmtText(
                    "directory:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.DIRECTORY },
                );
                try printer.addFmtText(
                    "/{s}",
                    .{name},
                    .{},
                );
            },
            .Task => {
                try printer.addFmtText(
                    "tasklist:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.TASKLIST },
                );
                try printer.addFmtText(
                    " {s}",
                    .{name},
                    .{},
                );
            },
            else => {},
        }
        try printer.addText("\n", .{});
    }
    try printer.drain(writer);
}
