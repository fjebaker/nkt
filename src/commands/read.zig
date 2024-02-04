const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const tags = @import("../tags.zig");
const colors = @import("../colors.zig");

const State = @import("../State.zig");
const BlockPrinter = @import("../BlockPrinter.zig");
const Entry = @import("../Topology.zig").Entry;

const Self = @This();

pub const alias = [_][]const u8{ "r", "rp" };

pub const help = "Display the contentes of notes in various ways";
pub const extended_help =
    \\Print the contents of a journal or note to stdout
    \\  nkt read
    \\     <what>                what to print: name of a journal, or a note
    \\                             entry. if choice is ambiguous, will print both,
    \\                             else specify with the `--journal` or `--dir`
    \\                             flags
    \\     [@tags]               show only those entries that have been tagged with
    \\                             chosen tags.
    \\
++ cli.Selection.COLLECTION_FLAG_HELP ++
    \\     -n/--limit int        maximum number of entries to display (default: 25)
    \\     --date                print full date time (`YYYY-MM-DD HH:MM:SS`)
    \\     -a/--all              display all items (overwrites `--limit`)
    \\     --pretty/--nopretty   force pretty or no pretty printing
    \\     -p/--page             read via pager
    \\
    \\The alias `rp` is a short hand for `read --page`.
    \\
;

selection: cli.Selection = .{},
number: usize = 20,
all: bool = false,
full_date: bool = false,
pager: bool = false,
pretty: ?bool = null,
selected_tags: ?[][]const u8 = null,

const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    var self: Self = .{};
    var tag_list = std.ArrayList([]const u8).init(alloc);
    defer tag_list.deinit();

    itt.rewind();
    const prog_name = (try itt.next()).?.string;
    if (std.mem.eql(u8, prog_name, "rp")) self.pager = true;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        // handle other options
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is('a', "all")) {
                self.all = true;
            } else if (arg.is(null, "no-pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = false;
            } else if (arg.is(null, "pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = true;
            } else if (arg.is('p', "pager")) {
                self.pager = true;
            } else if (arg.is(null, "date")) {
                self.full_date = true;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.string[0] == '@') {
                try tag_list.append(arg.string[1..]);
                continue;
            }
        }
        // parse selection
        if (try self.selection.parse(arg, itt)) continue;
    }

    // don't pretty if to pager or being piped
    self.pretty = self.pretty orelse
        if (self.pager) false else !opts.piped;

    // update the tags field if any were passed
    if (tag_list.items.len > 0) {
        self.selected_tags = try tag_list.toOwnedSlice();
    }

    return self;
}

const NoSuchCollection = State.Error.NoSuchCollection;

pub fn pipeToPager(
    allocator: std.mem.Allocator,
    pager: []const []const u8,
    s: []const u8,
) !void {
    var proc = std.ChildProcess.init(
        pager,
        allocator,
    );

    proc.stdin_behavior = std.ChildProcess.StdIo.Pipe;
    proc.stdout_behavior = std.ChildProcess.StdIo.Inherit;
    proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;

    try proc.spawn();
    _ = try proc.stdin.?.write(s);
    proc.stdin.?.close();
    proc.stdin = null;
    _ = try proc.wait();
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    if (self.pager) {
        var buf = std.ArrayList(u8).init(state.allocator);
        defer buf.deinit();
        try read(self, state, buf.writer());
        try pipeToPager(state.allocator, state.topology.pager, buf.items);
    } else {
        try read(self, state, out_writer);
    }
}

fn read(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const N = if (self.all) null else self.number;
    var printer = BlockPrinter.init(
        state.allocator,
        .{ .max_lines = N, .pretty = self.pretty.? },
    );
    defer printer.deinit();

    const tag_infos = state.getTagInfo();
    const selected_tags = if (self.selected_tags) |names|
        try tags.makeTagList(
            state.allocator,
            names,
            tag_infos,
        )
    else
        null;
    defer if (selected_tags) |st| state.allocator.free(st);

    if (self.selection.item != null) {
        const selected: State.MaybeItem =
            (try self.selection.find(state)) orelse
            return NoSuchCollection;

        if (selected.note) |note| {
            try readNote(note, &printer);
        }
        if (selected.day) |day| {
            printer.addTagInfo(state.getTagInfo());
            try self.readDay(day, selected_tags, state, &printer);
        }
        if (selected.task) |task| {
            printer.format_printer.opts.max_lines = null;
            printer.addTagInfo(tag_infos);
            try self.readTask(task, &printer);
        }
    } else if (self.selection.collection) |w| switch (w.container) {
        // if no selection, but a collection
        .Journal => {
            const journal = state.getJournal(w.name) orelse
                return NoSuchCollection;
            try self.readJournal(journal, selected_tags, state, &printer);
        },
        else => unreachable, // todo
    } else {
        // default behaviour
        const journal = state.getJournal("diary").?;
        printer.addTagInfo(tag_infos);
        try self.readJournal(journal, selected_tags, state, &printer);
    }

    try printer.drain(out_writer);
}

pub fn readNote(
    note: State.Item,
    printer: *BlockPrinter,
) !void {
    const content = try note.Note.read();
    try printer.addBlock("", .{});
    _ = try printer.addToCurrent(content, .{});
}

pub fn readDay(
    self: *Self,
    day: State.Item,
    selected_tags: ?[]const tags.Tag,
    state: *State,
    printer: *BlockPrinter,
) !void {
    const alloc = day.Day.journal.mem.allocator();

    // read all entries
    const all_entries = try day.Day.journal.readEntries(day.Day.day);

    // if tags are selected, filter only those entries
    const filtered_entries = if (selected_tags) |tgs|
        try tags.filterTagged(Entry, state.allocator, all_entries, tgs)
    else
        null;
    defer if (filtered_entries) |fe| state.allocator.free(fe);
    const entries = filtered_entries orelse all_entries;

    // no print if there are no entries for this day
    if (entries.len == 0) return;

    const date = utils.dateFromMs(day.Day.day.created);
    const day_of_week = try utils.dayOfWeek(alloc, date);
    const month = try utils.monthOfYear(alloc, date);

    try printer.addFormatted(
        .Heading,
        "## Journal: {s} {s} of {s}",
        .{ day.getName(), day_of_week, month },
        .{},
    );

    if (self.full_date) {
        try self.addItems(entries, .FullTime, state, printer);
    } else {
        try self.addItems(entries, .ClockTime, state, printer);
    }
}

pub fn readJournal(
    self: *Self,
    journal: *State.Collection,
    selected_tags: ?[]const tags.Tag,
    state: *State,
    printer: *BlockPrinter,
) !void {
    const alloc = printer.format_printer.mem.allocator();
    var day_list = try journal.getAll(alloc);

    if (day_list.len == 0) {
        try printer.addBlock("-- Empty --\n", .{});
        return;
    }

    journal.sort(day_list, .Created);
    std.mem.reverse(State.Item, day_list);

    var line_count: usize = 0;
    const last = for (0.., day_list) |i, *day| {
        const entries = try journal.Journal.readEntries(day.Day.day);
        line_count += entries.len;
        if (!printer.couldFit(line_count)) {
            break i;
        }
    } else day_list.len -| 1;

    printer.reverse();
    for (day_list[0 .. last + 1]) |day| {
        try self.readDay(day, selected_tags, state, printer);
        if (!printer.couldFit(1)) break;
    }
    printer.reverse();
}

fn addItems(
    _: *Self,
    entries: []Entry,
    comptime format: enum { FullTime, ClockTime },
    state: *State,
    printer: *BlockPrinter,
) !void {
    const offset = if (printer.remaining()) |rem| entries.len -| rem else 0;
    const tag_infos = state.getTagInfo();

    // the previously printed entry
    var previous: ?Entry = null;

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
        const date = utils.dateFromMs(entry.created);
        switch (format) {
            .ClockTime => {
                const time_of_day = try utils.formatTimeBuf(date);
                try printer.addFormatted(
                    .Item,
                    "{s} | {s}",
                    .{ time_of_day, entry.item },
                    .{},
                );
            },
            .FullTime => {
                const full_time = try utils.formatDateTimeBuf(date);
                try printer.addFormatted(
                    .Item,
                    "{s} | {s}",
                    .{ full_time, entry.item },
                    .{},
                );
            },
        }

        if (entry.tags.len > 0) {
            try printer.addToCurrent(" ", .{ .is_counted = false });
        }
        for (entry.tags) |tag| {
            try printer.addToCurrent("@", .{
                .fmt = try tags.getTagFormat(
                    printer.format_printer.mem.allocator(),
                    tag_infos,
                    tag.name,
                ),
                .is_counted = false,
            });
        }

        try printer.addToCurrent("\n", .{ .is_counted = false });
        previous = entry;
    }
}

const HEADING_FORMAT = colors.UNDERLINED.bold().fixed();
const URGENT_FORMAT = colors.RED.bold().fixed();
const WARN_FORMAT = colors.YELLOW.fixed();
const DIM_FORMAT = colors.DIM.fixed();
const COMPLETED_FORMAT = colors.GREEN.fixed();

fn readTask(
    _: *Self,
    task: State.Item,
    printer: *BlockPrinter,
) !void {
    const t = task.Task.task;
    const status = t.status(utils.Date.now());

    const due_s = if (t.due) |due|
        &try utils.formatDateTimeBuf(utils.dateFromMs(due))
    else
        "no date set";

    const completed_s = if (t.completed) |compl|
        &try utils.formatDateTimeBuf(utils.dateFromMs(compl))
    else
        "not completed";

    try printer.addBlock("", .{});

    try printer.addFormatted(
        .Item,
        "Task" ++ " " ** 11 ++ ":   {s}\n\n",
        .{t.title},
        .{ .fmt = HEADING_FORMAT },
    );

    try addInfoLine(
        printer,
        "Created",
        "|",
        "  {s}\n",
        .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.created))},
        null,
    );
    try addInfoLine(
        printer,
        "Modified",
        "|",
        "  {s}\n",
        .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.modified))},
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
            .low => "  Low",
            .high => "* High",
            .urgent => "! Urgent",
        }},
        switch (t.importance) {
            .high => WARN_FORMAT,
            .low => DIM_FORMAT,
            .urgent => URGENT_FORMAT,
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
    try printer.addToCurrent("\nDetails:\n\n", .{ .fmt = HEADING_FORMAT });
    try printer.addToCurrent(t.details, .{});
    try printer.addToCurrent("\n", .{});
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
