const std = @import("std");
const cli = @import("../cli.zig");
const ttags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");
const abstractions = @import("../abstractions.zig");

const commands = @import("../commands.zig");
const Journal = @import("../topology/Journal.zig");
const Tasklist = @import("../topology/Tasklist.zig");
const Root = @import("../topology/Root.zig");

const colors = @import("../colors.zig");

const FormatPrinter = @import("../printers.zig").FormatPrinter;
const BlockPrinter = @import("../printers.zig").BlockPrinter;

const Self = @This();

pub const alias = [_][]const u8{ "r", "rp" };

pub const short_help = "Read notes, task details, and journals.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "item",
    "Selected item (see `help select` for the formatting). If not argument is provided, defaults to reading the last `--limit` entries of the default journal.",
    .{ .required = false },
) ++
    &[_]cli.ArgumentDescriptor{
    .{
        .arg = "@tag1,@tag2,...",
        .help = "Show only entries or note sections that contain one of the following tags",
        .parse = false,
    },
    .{
        .arg = "-n/--limit limit",
        .help = "The maximum number of entries to display of a journal",
        .default = "25",
        .argtype = usize,
    },
    .{
        .arg = "-d/--date",
        .help = "Display the full date format (`YYYY-MM-DD HH:MM:SS`)",
    },
    .{
        .arg = "-a/--all",
        .help = "Display all items (overwrites `--limit`)",
    },
    .{
        .arg = "-t/--tasks name",
        .help = "Interweave changes to the (default tasklist) tasks in the printout of a journal. This argument can be `none` / `off` to disable intereacing, `all` to show all tasklists, or a comma seperated list of tasklists to include. Default is to show for `all` except those ignored in the configuration file.",
    },
    .{
        .arg = "-p/--page",
        .help = "Read the item through the configured pager",
    },
});

tags: []const []const u8,
args: arguments.Parsed,
selection: selections.Selection,
include_tasks: ?[]const []const u8,

fn addTag(tag_list: *std.ArrayList([]const u8), arg: []const u8) !void {
    const tag_name = ttags.getTagString(arg) catch |err| {
        return cli.throwError(err, "{s}", .{arg});
    };
    if (tag_name) |name| {
        try tag_list.append(name);
    } else {
        return cli.throwError(
            cli.CLIErrors.BadArgument,
            "tag format: tags must begin with `@`",
            .{},
        );
    }
}

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var tag_list = std.ArrayList([]const u8).init(allocator);
    defer tag_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) try itt.throwUnknownFlag();
            try addTag(&tag_list, arg.string);
        }
    }

    var args = try parser.getParsed();
    if (args.item) |item| {
        if (item[0] == '@') {
            try addTag(&tag_list, item);
            // don't try and process as selection
            args.item = null;
        }
    }
    const selection = try selections.fromArgs(
        arguments.Parsed,
        args.item,
        args,
    );

    const include_tasks = b: {
        if (args.tasks) |tasks| {
            var task_itt = std.mem.splitAny(u8, tasks, ",");
            var task_list = std.ArrayList([]const u8).init(allocator);
            defer task_list.deinit();
            while (task_itt.next()) |opt| {
                try task_list.append(opt);
            }
            break :b try task_list.toOwnedSlice();
        } else {
            break :b null;
        }
    };

    return .{
        .tags = try tag_list.toOwnedSlice(),
        .selection = selection,
        .args = args,
        .include_tasks = include_tasks,
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

    // if nothing is selected, we default
    if (self.selection.selector == null and
        self.selection.collection_type == null and
        self.selection.collection_name == null)
    {
        self.selection.collection_type = .CollectionJournal;
        self.selection.collection_name = root.info.default_journal;
    }

    var item = try self.selection.resolveReportError(root);

    // validate the task argument
    switch (item) {
        .Day => {},
        .Collection => |c| {
            switch (c) {
                .journal => {},
                else => {
                    if (self.include_tasks != null) return cli.throwError(
                        cli.CLIErrors.BadArgument,
                        "Cannot specify -t/--tasks when selecting '{s}'",
                        .{@tagName(c)},
                    );
                },
            }
        },
        else => {
            if (self.include_tasks != null) return cli.throwError(
                cli.CLIErrors.BadArgument,
                "Cannot specify -t/--tasks when selecting '{s}'",
                .{@tagName(item)},
            );
        },
    }

    const selected_tags = try utils.parseAndAssertValidTags(
        allocator,
        root,
        null,
        self.tags,
    );
    defer allocator.free(selected_tags);

    const N = try extractLineLimit(self.args);
    const tdl = try root.getTagDescriptorList();

    var bprinter = BlockPrinter.init(allocator, .{
        .max_lines = N,
        .tag_descriptors = tdl.tags,
        .pretty = !opts.piped,
    });
    defer bprinter.deinit();

    switch (item) {
        .Day => |*day| {
            const tasks = try self.getRelevantTasks(allocator, root);
            defer allocator.free(tasks);

            var task_events = try abstractions.TaskEventList.init(allocator, tasks);
            defer task_events.deinit();

            const events = task_events.eventsOnDay(day.day.getDate());
            _ = try self.readDay(
                allocator,
                root,
                &day.journal,
                day.day,
                events,
                selected_tags,
                tdl.tags,
                &bprinter,
            );
        },
        .Task => |*task| {
            try self.printTask(task.task, &bprinter);
        },
        .Collection => |*c| {
            switch (c.*) {
                .journal => |*j| try self.readJournal(
                    root,
                    allocator,
                    j,
                    selected_tags,
                    tdl.tags,
                    &bprinter,
                ),
                // TODO: handle this better
                else => unreachable,
            }
        },
        .Note => |*n| {
            const content = try root.fs.?.readFileAlloc(allocator, n.note.path);
            defer allocator.free(content);

            const ext = n.note.getExtension();
            if (root.getTextCompiler(ext)) |cmp| {
                try cmp.processText(writer, content, root);
            } else {
                try writer.writeAll(content);
            }
        },
        inline else => |k| {
            std.debug.print(">> {any}\n", .{k});
        },
    }

    bprinter.reverse();
    try bprinter.drain(writer);
}

fn getRelevantTasks(
    self: Self,
    allocator: std.mem.Allocator,
    root: *Root,
) ![]const Tasklist.Task {
    if (self.include_tasks) |it| {
        if (it.len == 1 and !std.mem.eql(u8, "all", it[0])) {
            var task_list = std.ArrayList(Tasklist.Task).init(allocator);
            defer task_list.deinit();

            if (it.len == 1) {
                const no_tasks = std.mem.eql(u8, "none", it[0]) or
                    std.mem.eql(u8, "off", it[0]);
                if (no_tasks) {
                    return try task_list.toOwnedSlice();
                }
            }

            // validate the tasklist argument
            for (it) |name| {
                if (std.mem.eql(u8, "all", name) or std.mem.eql(u8, "no", name)) {
                    return cli.throwError(
                        cli.CLIErrors.BadArgument,
                        "Cannot specify 'all' or 'no' when also specifying tasklists",
                        .{},
                    );
                }

                const tl = (try root.getTasklist(name)) orelse
                    return cli.throwError(
                    Root.Error.NoSuchCollection,
                    "Tasklist '{s}' does not exist",
                    .{name},
                );

                try task_list.appendSlice(tl.getInfo().tasks);
            }

            return try task_list.toOwnedSlice();
        }
    }

    return try root.getAllTasks(
        allocator,
        .{ .use_exclude_list = true },
    );
}

fn extractLineLimit(args: arguments.Parsed) !?usize {
    if (args.all) return null;
    return args.limit;
}

fn readJournal(
    self: *Self,
    root: *Root,
    allocator: std.mem.Allocator,
    j: *Journal,
    selected_tags: []const ttags.Tag,
    tag_descriptors: []const ttags.Tag.Descriptor,
    printer: *BlockPrinter,
) !void {
    std.log.default.debug("Reading journal '{s}'", .{j.descriptor.name});

    const tasks = try self.getRelevantTasks(allocator, root);
    defer allocator.free(tasks);

    var task_events = try abstractions.TaskEventList.init(allocator, tasks);
    defer task_events.deinit();

    var line_count: usize = 0;
    const j_info = j.getInfo();
    for (0..j_info.days.len) |i| {
        const day_info = j_info.days[j_info.days.len - 1 - i];
        const day = j.getDay(day_info.name).?;

        const events = task_events.eventsOnDay(day.getDate());

        line_count += try self.readDay(
            allocator,
            root,
            j,
            day,
            events,
            selected_tags,
            tag_descriptors,
            printer,
        );

        if (printer.format_printer.opts.max_lines) |N| {
            if (line_count >= N) {
                std.log.default.debug("Out of lines {d} >= {d}", .{ line_count, N });
                break;
            }
        }
    }
}

fn filterTags(
    allocator: std.mem.Allocator,
    selected_tags: []const ttags.Tag,
    entries: []const abstractions.EntryOrTaskEvent,
) ![]abstractions.EntryOrTaskEvent {
    var list = std.ArrayList(abstractions.EntryOrTaskEvent).init(allocator);
    defer list.deinit();

    for (entries) |entry| {
        const ts = switch (entry) {
            .entry => |e| e.tags,
            .task_event => |t| t.task.tags,
        };
        if (ttags.hasUnion(selected_tags, ts)) {
            try list.append(entry);
        }
    }
    return list.toOwnedSlice();
}

fn readDay(
    self: *Self,
    allocator: std.mem.Allocator,
    _: *Root,
    j: *Journal,
    day: Journal.Day,
    task_events: []const abstractions.TaskEvent,
    selected_tags: []const ttags.Tag,
    tag_descriptors: []const ttags.Tag.Descriptor,
    printer: *BlockPrinter,
) !usize {
    std.log.default.debug("Reading day '{s}'", .{day.name});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // read the entries of that day
    const entries = try j.getEntries(day);

    // combine with task events
    const all = try abstractions.entryOrTaskEventList(
        arena.allocator(),
        entries,
        task_events,
    );
    // no print if there is nothing for this day
    if (all.len == 0) return 0;

    // filter tags
    const filtered = if (selected_tags.len > 0) try filterTags(
        arena.allocator(),
        selected_tags,
        all,
    ) else all;
    if (filtered.len == 0) return 0;

    std.sort.insertion(
        abstractions.EntryOrTaskEvent,
        filtered,
        {},
        abstractions.EntryOrTaskEvent.timeAscending,
    );

    return try self.printEntriesOrEvents(
        day,
        filtered,
        tag_descriptors,
        printer,
    );
}

fn printEntriesOrEvents(
    self: *const Self,
    day: Journal.Day,
    entries: []const abstractions.EntryOrTaskEvent,
    tag_descriptors: []const ttags.Tag.Descriptor,
    printer: *BlockPrinter,
) !usize {
    const local_date =
        day.created.toDate();

    try printer.addFormatted(
        .Heading,
        "## Journal: {s} {s} of {s}",
        .{
            try time.formatDateBuf(local_date),
            try time.dayOfWeek(local_date),
            try time.monthOfYear(local_date),
        },
        .{ .is_counted = false },
    );

    const offset = if (printer.remaining()) |rem| entries.len -| rem else 0;

    var entries_written: usize = 0;
    var previous: ?abstractions.EntryOrTaskEvent = null;
    for (entries[offset..]) |entry| {
        // if there is more than an hour between two entries, print a newline
        // to separate clearer
        if (previous) |prev| {
            const t_diff = time.absTimeDiff(prev.getTime(), entry.getTime());
            if (t_diff > std.time.ms_per_hour) {
                try printer.addToCurrent("\n", .{ .is_counted = false });
            }
        }

        switch (entry) {
            .entry => |e| try self.printEntry(
                e,
                tag_descriptors,
                printer,
            ),
            .task_event => |t| try self.printTaskEvent(
                t,
                tag_descriptors,
                printer,
            ),
        }

        entries_written += 1;
        previous = entry;
    }

    return entries_written;
}

fn printEntry(
    self: *const Self,
    entry: Journal.Entry,
    tag_descriptors: []const ttags.Tag.Descriptor,
    printer: *BlockPrinter,
) !void {
    const entry_date = entry.created.toDate();

    const long_date = self.args.date;
    const formated: []const u8 = if (!long_date)
        &try time.formatTimeBuf(entry_date)
    else
        &try time.formatDateTimeBuf(entry_date);

    try printer.addFormatted(
        .Item,
        "{s} | {s}",
        .{ formated, entry.text },
        .{},
    );

    if (entry.tags.len > 0) {
        try printer.addToCurrent(" ", .{ .is_counted = false });
        for (entry.tags) |tag| {
            try printer.addToCurrent("@", .{
                .fmt = FormatPrinter.getTagFormat(
                    tag_descriptors,
                    tag.name,
                ),
                .is_counted = false,
            });
        }
    }

    try printer.addToCurrent("\n", .{ .is_counted = false });
}

fn printTaskEvent(
    self: *const Self,
    t: abstractions.TaskEvent,
    _: []const ttags.Tag.Descriptor,
    printer: *BlockPrinter,
) !void {
    const entry_date = t.getTime().toDate();

    const long_date = self.args.date;
    const formated: []const u8 = if (!long_date)
        &try time.formatTimeBuf(entry_date)
    else
        &try time.formatDateTimeBuf(entry_date);

    try printer.addFormatted(
        .Item,
        "{s} | {s} '{s}' (/{x:0>5})",
        .{
            formated,
            switch (t.event) {
                .Archived => "archived",
                .Created => "created",
                .Done => "completed",
            },
            t.task.outcome,
            @as(u20, @intCast(utils.getMiniHash(t.task.hash, 5))),
        },
        .{ .fmt = colors.DIM.italic() },
    );

    try printer.addToCurrent("\n", .{ .is_counted = false });
}

const HEADING_FORMAT = colors.UNDERLINED.bold();
const URGENT_FORMAT = colors.RED.bold();
const WARN_FORMAT = colors.YELLOW;
const DIM_FORMAT = colors.DIM;
const COMPLETED_FORMAT = colors.GREEN;

fn printTask(
    _: *Self,
    t: Tasklist.Task,
    printer: *BlockPrinter,
) !void {
    const status = t.getStatus(time.Time.now());

    const due_s = if (t.due) |due|
        &try time.formatDateTimeBuf(due.toDate())
    else
        "no date set";

    const completed_s = if (t.done) |compl|
        &try time.formatDateTimeBuf(compl.toDate())
    else
        "not completed";

    try printer.addBlock("", .{});

    try printer.addFormatted(
        .Item,
        "Task" ++ " " ** 11 ++ ":   {s}\n\n",
        .{t.outcome},
        .{ .fmt = HEADING_FORMAT },
    );

    try addInfoLine(
        printer,
        "Created",
        "|",
        "  {s}\n",

        .{&try time.formatDateTimeBuf(t.created.toDate())},
        null,
    );
    try addInfoLine(
        printer,
        "Modified",
        "|",
        "  {s}\n",
        .{&try time.formatDateTimeBuf(t.modified.toDate())},
        null,
    );
    try addInfoLine(
        printer,
        "Due",
        "|",
        "  {s}\n",
        .{due_s},
        switch (status) {
            .PastDue => URGENT_FORMAT,
            .NearlyDue => WARN_FORMAT,
            else => DIM_FORMAT,
        },
    );
    try addInfoLine(
        printer,
        "Importance",
        "|",
        "{s}\n",
        .{switch (t.importance) {
            .Low => "  Low",
            .High => "* High",
            .Urgent => "! Urgent",
        }},
        switch (t.importance) {
            .High => WARN_FORMAT,
            .Low => DIM_FORMAT,
            .Urgent => URGENT_FORMAT,
        },
    );
    try addInfoLine(
        printer,
        "Completed",
        "|",
        "  {s}\n",
        .{completed_s},
        switch (status) {
            .Done => COMPLETED_FORMAT,
            else => DIM_FORMAT,
        },
    );

    if (t.details) |details| {
        try printer.addToCurrent("\nDetails:\n\n", .{ .fmt = HEADING_FORMAT });
        try printer.addToCurrent(details, .{});
        try printer.addToCurrent("\n", .{});
    }
}

fn addInfoLine(
    printer: *BlockPrinter,
    comptime key: []const u8,
    comptime delim: []const u8,
    comptime value_fmt: []const u8,
    args: anytype,
    fmt: ?colors.Farbe,
) !void {
    const padd = 15 - key.len;
    try printer.addToCurrent(key, .{});
    try printer.addToCurrent(" " ** padd ++ delim ++ " ", .{});
    try printer.addFormatted(.Item, value_fmt, args, .{ .fmt = fmt });
}
