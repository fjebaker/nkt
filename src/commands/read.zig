const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Journal = @import("../topology/Journal.zig");
const Tasklist = @import("../topology/Tasklist.zig");
const Root = @import("../topology/Root.zig");

const colors = @import("../colors.zig");

const FormatPrinter = @import("../FormatPrinter.zig");
const BlockPrinter = @import("../BlockPrinter.zig");

const Self = @This();

pub const DEFAULT_LINE_COUNT = 20;

pub const alias = [_][]const u8{ "r", "rp" };

pub const short_help = "Read notes, task details, and journals.";
pub const long_help = short_help;

pub const arguments = cli.ArgumentsHelp(selections.selectHelp(
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
        .help = "The maximum number of entries to display of a journal (default: 25).",
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
        .arg = "-p/--page",
        .help = "Read the item through the configured pager",
    },
}, .{});

tags: []const []const u8,
args: arguments.ParsedArguments,
selection: selections.Selection,

fn addTag(tag_list: *std.ArrayList([]const u8), arg: []const u8) !void {
    const tag_name = tags.getTagString(arg) catch |err| {
        try cli.throwError(err, "{s}", .{arg});
        unreachable;
    };
    if (tag_name) |name| {
        try tag_list.append(name);
    } else {
        try cli.throwError(
            cli.CLIErrors.BadArgument,
            "tag format: tags must begin with `@`",
            .{},
        );
        unreachable;
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
        arguments.ParsedArguments,
        args.item,
        args,
    );
    return .{
        .tags = try tag_list.toOwnedSlice(),
        .selection = selection,
        .args = args,
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
    defer item.deinit();

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
            _ = try self.readDay(
                allocator,
                &day.journal,
                day.day,
                selected_tags,
                tdl.tags,
                &bprinter,
                opts.tz,
            );
        },
        .Task => |*task| {
            try self.printTask(task.task, &bprinter, opts.tz);
        },
        .Collection => |*c| {
            switch (c.*) {
                .journal => |*j| try self.readJournal(
                    allocator,
                    j,
                    selected_tags,
                    tdl.tags,
                    &bprinter,
                    opts.tz,
                ),
                // TODO: handle this better
                else => unreachable,
            }
        },
        inline else => |k| {
            std.debug.print(">> {any}\n", .{k});
        },
    }

    bprinter.reverse();
    try bprinter.drain(writer);
}

fn extractLineLimit(args: arguments.ParsedArguments) !?usize {
    if (args.all orelse false) return null;
    if (args.limit) |str| {
        return try std.fmt.parseInt(usize, str, 10);
    }
    return DEFAULT_LINE_COUNT;
}

fn readJournal(
    self: *Self,
    allocator: std.mem.Allocator,
    j: *Journal,
    selected_tags: []const tags.Tag,
    tag_descriptors: []const tags.Tag.Descriptor,
    printer: *BlockPrinter,
    tz: time.TimeZone,
) !void {
    const now = time.timeNow();
    var line_count: usize = 0;
    for (0..j.info.days.len) |i| {
        const day = j.getDayOffsetIndex(now, i) orelse continue;
        line_count += try self.readDay(
            allocator,
            j,
            day,
            selected_tags,
            tag_descriptors,
            printer,
            tz,
        );

        if (printer.format_printer.opts.max_lines) |N| {
            if (line_count >= N) break;
        }
    }
}

fn filterTags(
    allocator: std.mem.Allocator,
    selected_tags: []const tags.Tag,
    entries: []const Journal.Entry,
) ![]const Journal.Entry {
    var list = std.ArrayList(Journal.Entry).init(allocator);
    defer list.deinit();

    for (entries) |entry| {
        if (tags.hasUnion(selected_tags, entry.tags)) {
            try list.append(entry);
        }
    }
    return list.toOwnedSlice();
}

fn readDay(
    self: *Self,
    allocator: std.mem.Allocator,
    j: *Journal,
    day: Journal.Day,
    selected_tags: []const tags.Tag,
    tag_descriptors: []const tags.Tag.Descriptor,
    printer: *BlockPrinter,
    tz: time.TimeZone,
) !usize {
    // read the entries of that day
    const entries = try j.getEntries(day);
    // no print if there are no entries for this day
    if (entries.len == 0) return 0;

    // TODO: filter the entries by tags
    const filtered = if (selected_tags.len > 0)
        try filterTags(allocator, selected_tags, entries)
    else
        entries;
    defer if (selected_tags.len > 0) allocator.free(filtered);

    if (filtered.len == 0) return 0;

    return try self.printEntries(
        day,
        filtered,
        tag_descriptors,
        printer,
        tz,
    );
}

fn printEntries(
    self: *const Self,
    day: Journal.Day,
    entries: []const Journal.Entry,
    tag_descriptors: []const tags.Tag.Descriptor,
    printer: *BlockPrinter,
    tz: time.TimeZone,
) !usize {
    const local_date = tz.makeLocal(
        time.dateFromTime(day.created),
    );

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
    var previous: ?Journal.Entry = null;
    for (entries[offset..]) |entry| {
        // if there is more than an hour between two entries, print a newline
        // to separate clearer
        if (previous) |prev| {
            const diff = if (prev.created < entry.created)
                entry.created - prev.created
            else
                prev.created - entry.created;
            if (diff > std.time.ms_per_hour) {
                try printer.addToCurrent("\n", .{ .is_counted = false });
            }
        }

        const entry_date = tz.makeLocal(
            time.dateFromTime(entry.created),
        );

        const long_date = self.args.date orelse false;
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
        entries_written += 1;

        if (entry.tags.len > 0) {
            try printer.addToCurrent(" ", .{ .is_counted = false });
            for (entry.tags) |tag| {
                try printer.addToCurrent("@", .{
                    .fmt = try FormatPrinter.getTagFormat(
                        printer.format_printer.mem.allocator(),
                        tag_descriptors,
                        tag.name,
                    ),
                    .is_counted = false,
                });
            }
        }

        try printer.addToCurrent("\n", .{ .is_counted = false });
        previous = entry;
    }

    return entries_written;
}

const HEADING_FORMAT = colors.UNDERLINED.bold().fixed();
const URGENT_FORMAT = colors.RED.bold().fixed();
const WARN_FORMAT = colors.YELLOW.fixed();
const DIM_FORMAT = colors.DIM.fixed();
const COMPLETED_FORMAT = colors.GREEN.fixed();

fn printTask(
    _: *Self,
    t: Tasklist.Task,
    printer: *BlockPrinter,
    tz: time.TimeZone,
) !void {
    const status = t.getStatus(time.timeNow());

    const due_s = if (t.due) |due|
        &try time.formatDateTimeBuf(tz.makeLocal(time.dateFromTime(due)))
    else
        "no date set";

    const completed_s = if (t.done) |compl|
        &try time.formatDateTimeBuf(tz.makeLocal(time.dateFromTime(compl)))
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
        .{&try time.formatDateTimeBuf(tz.makeLocal(time.dateFromTime(t.created)))},
        null,
    );
    try addInfoLine(
        printer,
        "Modified",
        "|",
        "  {s}\n",
        .{&try time.formatDateTimeBuf(tz.makeLocal(time.dateFromTime(t.modified)))},
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
