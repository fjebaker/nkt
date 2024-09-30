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

const logger = std.log.scoped(.cmd_list);

pub const alias = [_][]const u8{"ls"};

pub const short_help = "List collections and other information in various ways.";
pub const long_help = short_help;

const MUTUAL_FIELDS: []const []const u8 = &.{
    "sort",
};

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "--sort how",
        .help = "How to sort the item lists. Possible values are 'alpha[betical]', 'modified', 'canonical' or 'created'. ",
        .default = "canonical",
        .completion = "{compadd alpha alphabetical modified created canonical}",
    },
    .{
        .arg = "what",
        .help = "Can be 'tags', 'compilers', a specific @tag, or the name of a collection.",
        .completion = "{compadd tags compilers $(nkt completion list --all-collections)}",
    },
    .{
        .arg = "--type collection_type",
        .help = "Only show items of the specified collection type. Can be 'directory', 'journal', 'tasklist'.",
        .completion = "{compadd d dir directory j journal t tl tasklist}",
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
        .help = "Display the hash identifiers of the tasks.",
    },
    .{
        .arg = "--long-hash",
        .help = "Display the long (not shortened) hash identifiers of the tasks.",
    },
    .{
        .arg = "--done",
        .help = "If a tasklist is selected, enables listing tasks marked as 'done'",
    },
    .{
        .arg = "--archived",
        .help = "If a tasklist is selected, enables listing tasks marked as 'archived'",
    },
    .{
        .arg = "--date",
        .help = "Show more or additional date infomation (e.g. when something was created).",
    },
});

const ListSelection = union(enum) {
    Directory: struct {
        date: bool = false,
        note: ?[]const u8,
        name: []const u8,
    },
    Journal: struct {
        date: bool = false,
        name: []const u8,
    },
    Tasklist: struct {
        date: bool = false,
        name: []const u8,
        done: bool,
        hash: bool,
        long_hash: bool,
        archived: bool,
    },
    NamedSelection: struct {
        date: bool = false,
        name: []const u8,
        ctype: ?Root.CollectionType = null,
    },
    Collections: void,
    Tags: void,
    Stacks: void,
    Tag: struct {
        date: bool = false,
        name: []const u8,
        ctype: ?Root.CollectionType = null,
    },
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
        .Directory => |i| try self.listDirectory(allocator, i, root, writer, opts),
        .Journal => |i| try listJournal(i, root, writer, opts),
        .Tasklist => |i| try listTasklist(allocator, i, root, writer, self.sort, opts),
        .Stacks => |i| try listStacks(allocator, i, root, writer, opts),
        .Tag => |t| try listTagged(allocator, t, root, writer, opts),
        .NamedSelection => |ns| try self.listNamedSelection(
            allocator,
            ns,
            root,
            writer,
            opts,
        ),
    }
}

fn listNamedSelection(
    self: *Self,
    allocator: std.mem.Allocator,
    ns: utils.TagType(ListSelection, "NamedSelection"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const collection_selector = selections.Selection{
        .collection_name = ns.name,
        .collection_provided = true,
    };

    const col = (try collection_selector.resolveReportError(root)).Collection;
    const extra_args = &.{ "what", "type", "date" };
    switch (col) {
        .directory => {
            const x = try processDirectoryArgs(
                ns.name,
                self.args,
                extra_args,
            );
            try self.listDirectory(
                allocator,
                x.Directory,
                root,
                writer,
                opts,
            );
        },
        .journal => {
            const x = try processJournalArgs(
                ns.name,
                self.args,
                extra_args,
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
                ns.name,
                self.args,
                extra_args,
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
        (MUTUAL_FIELDS ++ [_][]const u8{ "done", "archived", "long-hash", "hash", "date" } ++ extra_fields),
        "tasklist",
    );
    return .{ .Tasklist = .{
        .name = name,
        .done = args.done,
        .hash = args.hash,
        .long_hash = args.@"long-hash",
        .date = args.date,
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
        (MUTUAL_FIELDS ++ [_][]const u8{ "what", "date" } ++ extra_fields),
        "directory",
    );
    return .{ .Directory = .{
        .name = name,
        .note = args.what,
        .date = args.date,
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
        MUTUAL_FIELDS ++ [_][]const u8{"date"} ++ extra_fields,
        "journal",
    );
    return .{ .Journal = .{
        .name = name,
        .date = args.date,
    } };
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
                (MUTUAL_FIELDS ++ [_][]const u8{ "what", "type", "date" }),
                what,
            );
            return .{ .Tag = .{
                .name = what,
                .ctype = try toColType(args.type),
                .date = args.date,
            } };
        }

        // make sure none of the incompatible fields are selected
        return .{ .NamedSelection = .{
            .name = what,
            .ctype = try toColType(args.type),
        } };
    }

    try utils.ensureOnly(
        arguments.Parsed,
        args,
        MUTUAL_FIELDS,
        "collections",
    );

    return .{ .Collections = {} };
}

fn toColType(string: ?[]const u8) !?Root.CollectionType {
    const s = string orelse return null;
    const eq = std.mem.eql;
    if (eq(u8, s, "d") or eq(u8, s, "dir") or eq(u8, s, "directory")) {
        return .CollectionDirectory;
    }
    if (eq(u8, s, "j") or eq(u8, s, "journal")) {
        return .CollectionJournal;
    }
    if (eq(u8, s, "t") or eq(u8, s, "tl") or eq(u8, s, "tasklist")) {
        return .CollectionTasklist;
    }
    return cli.throwError(
        error.NoSuchCollection,
        "Collectiont type '{s}' is not a valid type.",
        .{s},
    );
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

const Counter = struct {
    notes: usize = 0,
    entries: usize = 0,
    tasks: usize = 0,
};

fn listTags(
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    var tdl = try root.getTagDescriptorList();
    tdl.sort(.Alphabetical);

    const items = try utils.getAllItems(allocator, root, .{});
    defer allocator.free(items);

    var counter = std.StringHashMap(Counter).init(allocator);
    defer counter.deinit();

    // get the number of each tagged
    for (items) |item| {
        const ts = item.getTags();
        for (ts) |tag| {
            const it = try counter.getOrPut(tag.name);
            if (!it.found_existing) it.value_ptr.* = .{};
            switch (item) {
                .Note => it.value_ptr.notes += 1,
                .Entry => it.value_ptr.entries += 1,
                .Task => it.value_ptr.tasks += 1,
                else => unreachable,
            }
        }
    }

    var printer = FormatPrinter.init(allocator, .{
        .pretty = !opts.piped,
        .tag_descriptors = tdl.tags,
    });
    defer printer.deinit();

    try printer.addText("Tags:\n", .{});
    for (tdl.tags) |info| {
        const count: Counter = counter.get(info.name) orelse .{};
        try printer.addFmtText(" - @{s} ", .{info.name}, .{});
        try printer.addFmtText(
            "(items: {d})",
            .{count.entries + count.notes + count.tasks},
            .{ .fmt = colors.DIM },
        );
        try printer.addText("\n", .{});
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
            .hash = tl.hash or tl.long_hash,
            .full_hash = tl.long_hash,
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
    self: *const Self,
    allocator: std.mem.Allocator,
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
        return;
    }

    var items = try std.ArrayList(Item).initCapacity(
        allocator,
        dir_info.notes.len,
    );
    defer items.deinit();

    for (dir_info.notes) |note| {
        try items.append(
            .{ .Note = .{ .directory = dir, .note = note } },
        );
    }

    sortItems(items.items, self.sort.how);

    try printItems(
        allocator,
        writer,
        items.items,
        (try root.getTagDescriptorList()).tags,
        opts,
        .{ .created = d.date },
    );
}

fn sortItems(items: []Item, how: Tasklist.SortingOptions.Method) void {
    switch (how) {
        inline else => |h| {
            const sort_fn = switch (h) {
                .alpha, .alphabetical, .canonical => Item.alphaDescending,
                .modified => Item.modifiedDescending,
                .created => Item.createdDescending,
            };
            std.sort.heap(Item, items, {}, sort_fn);
        },
    }
}

fn listTagged(
    allocator: std.mem.Allocator,
    t: utils.TagType(ListSelection, "Tag"),
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const now = time.Time.now();
    const st = try tags.parseInlineTags(allocator, t.name, now);
    defer allocator.free(st);

    var tl = try root.getTagDescriptorList();
    if (tl.findInvalidTags(st)) |_t| {
        return cli.throwError(
            error.InvalidTag,
            "'{s}' is not a valid tag",
            .{_t.name},
        );
    }

    const items = try utils.getAllItems(allocator, root, .{
        .directory = utils.isElseNull(
            Root.CollectionType.CollectionDirectory,
            t.ctype,
        ),
        .journal = utils.isElseNull(
            Root.CollectionType.CollectionJournal,
            t.ctype,
        ),
        .tasklist = utils.isElseNull(
            Root.CollectionType.CollectionTasklist,
            t.ctype,
        ),
    });
    defer allocator.free(items);

    var list = try std.ArrayList(Item).initCapacity(allocator, items.len);
    defer list.deinit();

    for (items) |item| {
        if (tags.hasUnion(item.getTags(), st)) {
            list.appendAssumeCapacity(item);
        }
    }

    // sort by last modified
    std.sort.heap(Item, list.items, {}, Item.modifiedDescending);

    try printItems(
        allocator,
        writer,
        list.items,
        (try root.getTagDescriptorList()).tags,
        opts,
        .{ .created = t.date },
    );
}

const PrintOptions = struct {
    created: bool = false,
};

pub fn printItems(
    allocator: std.mem.Allocator,
    writer: anytype,
    items: []const Item,
    tag_descriptors: []const tags.Tag.Descriptor,
    opts: commands.Options,
    popts: PrintOptions,
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
        if (popts.created) {
            try printer.addFmtText(
                "{s} ",
                .{try nd.getCreated().formatDateTime()},
                .{ .fmt = colors.DIM },
            );
        }
        switch (nd) {
            .Entry => {
                try printer.addFmtText(
                    "journal:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.JOURNAL },
                );
            },
            .Note => {
                try printer.addFmtText(
                    "directory:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.DIRECTORY },
                );
            },
            .Task => {
                try printer.addFmtText(
                    "tasklist:{s}",
                    .{nd.getCollectionName()},
                    .{ .fmt = colors.TASKLIST },
                );
            },
            else => {
                logger.warn("Cannot print {s}", .{@tagName(nd)});
            },
        }

        try printer.addFmtText(
            " {s}",
            .{name},
            .{},
        );

        switch (nd) {
            .Entry => |entry| {
                try printer.addFmtText(
                    " {s}",
                    .{entry.entry.text},
                    .{},
                );
            },
            else => {},
        }

        const item_tags = nd.getTags();

        if (item_tags.len > 0) {
            try printer.addText(" [tags:", .{ .fmt = colors.DIM });

            for (item_tags) |tag| {
                const fmt = FormatPrinter.getTagFormat(
                    tag_descriptors,
                    tag.name,
                );
                try printer.addFmtText(" @{s}", .{tag.name}, .{ .fmt = fmt });
            }

            try printer.addText("]", .{ .fmt = colors.DIM });
        }

        try printer.addText("\n", .{});
    }
    try printer.drain(writer);
}
