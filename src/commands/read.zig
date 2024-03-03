const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Journal = @import("../topology/Journal.zig");
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

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var tag_list = std.ArrayList([]const u8).init(allocator);
    defer tag_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) try itt.throwUnknownFlag();
            // tag parsing
            const tag_name = tags.getTagString(arg.string) catch |err| {
                try cli.throwError(err, "{s}", .{arg.string});
                unreachable;
            };
            if (tag_name) |name| {
                try tag_list.append(name);
            } else {
                try itt.throwBadArgument("tag format: tags must begin with `@`");
            }
        }
    }

    const args = try parser.getParsed();
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

    var bprinter = BlockPrinter.init(allocator, .{ .max_lines = N });
    defer bprinter.deinit();

    var tdl = try root.getTagDescriptorList();

    switch (item) {
        .Day => |*day| {
            _ = try self.readDay(
                &day.journal,
                day.day,
                selected_tags,
                tdl.tags,
                &bprinter,
                opts.tz,
            );
        },
        .Collection => |*c| {
            switch (c.*) {
                .journal => |*j| try self.readJournal(
                    j,
                    selected_tags,
                    tdl.tags,
                    &bprinter,
                    opts.tz,
                ),
                else => unreachable,
            }
        },
        inline else => |k| {
            std.debug.print(">> {any}\n", .{k});
        },
    }

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

fn readDay(
    self: *Self,
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
    _ = selected_tags;

    return try self.printEntries(
        day,
        entries,
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
    _ = previous;
    for (entries[offset..]) |entry| {
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
    }

    return entries_written;
}

// pub fn pipeToPager(
//     allocator: std.mem.Allocator,
//     pager: []const []const u8,
//     s: []const u8,
// ) !void {
//     var proc = std.ChildProcess.init(
//         pager,
//         allocator,
//     );

//     proc.stdin_behavior = std.ChildProcess.StdIo.Pipe;
//     proc.stdout_behavior = std.ChildProcess.StdIo.Inherit;
//     proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;

//     try proc.spawn();
//     _ = try proc.stdin.?.write(s);
//     proc.stdin.?.close();
//     proc.stdin = null;
//     _ = try proc.wait();
// }

// pub fn run(
//     self: *Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     if (self.pager) {
//         var buf = std.ArrayList(u8).init(state.allocator);
//         defer buf.deinit();
//         try read(self, state, buf.writer());
//         try pipeToPager(state.allocator, state.topology.pager, buf.items);
//     } else {
//         try read(self, state, out_writer);
//     }
// }

// fn read(
//     self: *Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     const N = if (self.all) null else self.number;
//     var printer = BlockPrinter.init(
//         state.allocator,
//         .{ .max_lines = N, .pretty = self.pretty.? },
//     );
//     defer printer.deinit();

//     const tag_infos = state.getTagInfo();
//     const selected_tags = if (self.selected_tags) |names|
//         try tags.makeTagList(
//             state.allocator,
//             names,
//             tag_infos,
//         )
//     else
//         null;
//     defer if (selected_tags) |st| state.allocator.free(st);

//     if (self.selection.item != null) {
//         const selected: State.MaybeItem =
//             (try self.selection.find(state)) orelse
//             return NoSuchCollection;

//         if (selected.note) |note| {
//             try readNote(note, &printer);
//         }
//         if (selected.day) |day| {
//             printer.addTagInfo(state.getTagInfo());
//             try self.readDay(day, selected_tags, state, &printer);
//         }
//         if (selected.task) |task| {
//             printer.format_printer.opts.max_lines = null;
//             printer.addTagInfo(tag_infos);
//             try self.readTask(task, &printer);
//         }
//     } else if (self.selection.collection) |w| switch (w.container) {
//         // if no selection, but a collection
//         .Journal => {
//             const journal = state.getJournal(w.name) orelse
//                 return NoSuchCollection;
//             try self.readJournal(journal, selected_tags, state, &printer);
//         },
//         else => unreachable, // todo
//     } else {
//         // default behaviour
//         const journal = state.getJournal("diary").?;
//         printer.addTagInfo(tag_infos);
//         try self.readJournal(journal, selected_tags, state, &printer);
//     }

//     try printer.drain(out_writer);
// }

// pub fn readNote(
//     note: State.Item,
//     printer: *BlockPrinter,
// ) !void {
//     const content = try note.Note.read();
//     try printer.addBlock("", .{});
//     _ = try printer.addToCurrent(content, .{});
// }

// pub fn readJournal(
//     self: *Self,
//     journal: *State.Collection,
//     selected_tags: ?[]const tags.Tag,
//     state: *State,
//     printer: *BlockPrinter,
// ) !void {
//     const alloc = printer.format_printer.mem.allocator();
//     var day_list = try journal.getAll(alloc);

//     if (day_list.len == 0) {
//         try printer.addBlock("-- Empty --\n", .{});
//         return;
//     }

//     journal.sort(day_list, .Created);
//     std.mem.reverse(State.Item, day_list);

//     var line_count: usize = 0;
//     const last = for (0.., day_list) |i, *day| {
//         const entries = try journal.Journal.readEntries(day.Day.day);
//         line_count += entries.len;
//         if (!printer.couldFit(line_count)) {
//             break i;
//         }
//     } else day_list.len -| 1;

//     printer.reverse();
//     for (day_list[0 .. last + 1]) |day| {
//         try self.readDay(day, selected_tags, state, printer);
//         if (!printer.couldFit(1)) break;
//     }
//     printer.reverse();
// }

// fn addItems(
//     _: *Self,
//     entries: []Entry,
//     comptime format: enum { FullTime, ClockTime },
//     state: *State,
//     printer: *BlockPrinter,
// ) !void {
//     const offset = if (printer.remaining()) |rem| entries.len -| rem else 0;
//     const tag_infos = state.getTagInfo();

//     // the previously printed entry
//     var previous: ?Entry = null;

//     for (entries[offset..]) |entry| {
//         // if there is more than an hour between two entries, print a newline
//         // to separate clearer
//         if (previous) |prev| {
//             const diff = if (prev.created < entry.created)
//                 entry.created - prev.created
//             else
//                 prev.created - entry.created;
//             if (diff > std.time.ms_per_hour) {
//                 try printer.addToCurrent("\n", .{ .is_counted = false });
//             }
//         }
//         const date = utils.dateFromMs(entry.created);
//         switch (format) {
//             .ClockTime => {
//                 const time_of_day = try utils.formatTimeBuf(date);
//                 try printer.addFormatted(
//                     .Item,
//                     "{s} | {s}",
//                     .{ time_of_day, entry.item },
//                     .{},
//                 );
//             },
//             .FullTime => {
//                 const full_time = try utils.formatDateTimeBuf(date);
//                 try printer.addFormatted(
//                     .Item,
//                     "{s} | {s}",
//                     .{ full_time, entry.item },
//                     .{},
//                 );
//             },
//         }

//         if (entry.tags.len > 0) {
//             try printer.addToCurrent(" ", .{ .is_counted = false });
//         }
//         for (entry.tags) |tag| {
//             try printer.addToCurrent("@", .{
//                 .fmt = try tags.getTagFormat(
//                     printer.format_printer.mem.allocator(),
//                     tag_infos,
//                     tag.name,
//                 ),
//                 .is_counted = false,
//             });
//         }

//         try printer.addToCurrent("\n", .{ .is_counted = false });
//         previous = entry;
//     }
// }

// const HEADING_FORMAT = colors.UNDERLINED.bold().fixed();
// const URGENT_FORMAT = colors.RED.bold().fixed();
// const WARN_FORMAT = colors.YELLOW.fixed();
// const DIM_FORMAT = colors.DIM.fixed();
// const COMPLETED_FORMAT = colors.GREEN.fixed();

// fn readTask(
//     _: *Self,
//     task: State.Item,
//     printer: *BlockPrinter,
// ) !void {
//     const t = task.Task.task;
//     const status = t.status(utils.Date.now());

//     const due_s = if (t.due) |due|
//         &try utils.formatDateTimeBuf(utils.dateFromMs(due))
//     else
//         "no date set";

//     const completed_s = if (t.completed) |compl|
//         &try utils.formatDateTimeBuf(utils.dateFromMs(compl))
//     else
//         "not completed";

//     try printer.addBlock("", .{});

//     try printer.addFormatted(
//         .Item,
//         "Task" ++ " " ** 11 ++ ":   {s}\n\n",
//         .{t.title},
//         .{ .fmt = HEADING_FORMAT },
//     );

//     try addInfoLine(
//         printer,
//         "Created",
//         "|",
//         "  {s}\n",
//         .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.created))},
//         null,
//     );
//     try addInfoLine(
//         printer,
//         "Modified",
//         "|",
//         "  {s}\n",
//         .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.modified))},
//         null,
//     );
//     try addInfoLine(
//         printer,
//         "Due",
//         "|",
//         "  {s}\n",
//         .{due_s},
//         switch (status) {
//             .PastDue => URGENT_FORMAT,
//             .NearlyDue => WARN_FORMAT,
//             else => DIM_FORMAT,
//         },
//     );
//     try addInfoLine(
//         printer,
//         "Importance",
//         "|",
//         "{s}\n",
//         .{switch (t.importance) {
//             .low => "  Low",
//             .high => "* High",
//             .urgent => "! Urgent",
//         }},
//         switch (t.importance) {
//             .high => WARN_FORMAT,
//             .low => DIM_FORMAT,
//             .urgent => URGENT_FORMAT,
//         },
//     );
//     try addInfoLine(
//         printer,
//         "Completed",
//         "|",
//         "  {s}\n",
//         .{completed_s},
//         switch (status) {
//             .Done => COMPLETED_FORMAT,
//             else => DIM_FORMAT,
//         },
//     );
//     try printer.addToCurrent("\nDetails:\n\n", .{ .fmt = HEADING_FORMAT });
//     try printer.addToCurrent(t.details, .{});
//     try printer.addToCurrent("\n", .{});
// }

// fn addInfoLine(
//     printer: *BlockPrinter,
//     comptime key: []const u8,
//     comptime delim: []const u8,
//     comptime value_fmt: []const u8,
//     args: anytype,
//     fmt: ?colors.Farbe,
// ) !void {
//     const padd = 15 - key.len;
//     try printer.addToCurrent(key, .{});
//     try printer.addToCurrent(" " ** padd ++ delim ++ " ", .{});
//     try printer.addFormatted(.Item, value_fmt, args, .{ .fmt = fmt });
// }
