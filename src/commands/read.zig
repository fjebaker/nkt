const std = @import("std");

const Chameleon = @import("chameleon").Chameleon;

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Printer = @import("../Printer.zig");
const Entry = @import("../collections/Topology.zig").Entry;

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
    \\
++ cli.Selection.COLLECTION_FLAG_HELP ++
    \\     -n/--limit int        maximum number of entries to display (default: 25)
    \\     --date                print full date time (`YYYY-MM-DD HH:MM:SS`)
    \\     --filename            use the filename as the print prefix
    \\     --all                 display all items (overwrites `--limit`)
    \\     -p/--page             read via pager
    \\
    \\The alias `rp` is a short hand for `read --page`.
    \\
;

selection: cli.Selection = .{},
number: usize = 20,
all: bool = false,
full_date: bool = false,
filename: bool = false,
pager: bool = false,
pretty: ?bool = null,

const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    var self: Self = .{};

    itt.rewind();
    const prog_name = (try itt.next()).?.string;
    if (std.mem.eql(u8, prog_name, "rp")) self.pager = true;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        // parse selection
        if (try self.selection.parse(arg, itt)) continue;

        // handle other options
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                self.all = true;
            } else if (arg.is('p', "pager")) {
                self.pager = true;
            } else if (arg.is(null, "date")) {
                self.full_date = true;
            } else if (arg.is(null, "filename")) {
                self.filename = true;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            return cli.CLIErrors.TooManyArguments;
        }
    }

    if (self.full_date and self.filename)
        return cli.SelectionError.IncompatibleSelection;

    // don't pretty if to pager or being piped
    self.pretty = self.pretty orelse
        if (self.pager) false else !opts.piped;

    return self;
}

const NoSuchCollection = State.Error.NoSuchCollection;

fn pipeToPager(
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
    var printer = Printer.init(state.allocator, N, self.pretty.?);
    defer printer.deinit();

    if (self.selection.item != null) {
        var selected: State.MaybeItem =
            (try self.selection.find(state)) orelse
            return NoSuchCollection;

        if (selected.note) |note| {
            try self.readNote(note, &printer);
        }
        if (selected.day) |day| {
            try self.readDay(day, &printer);
        }
        if (selected.task) |task| {
            printer.remaining = null;
            printer.indent = 2;
            try self.readTask(task, &printer);
        }
    } else if (self.selection.collection) |w| switch (w.container) {
        // if no selection, but a collection
        .Journal => {
            const journal = state.getJournal(w.name) orelse
                return NoSuchCollection;
            try self.readJournal(journal, &printer);
        },
        else => unreachable, // todo
    } else {
        // default behaviour
        const journal = state.getJournal("diary").?;
        try self.readJournal(journal, &printer);
    }

    try printer.drain(out_writer);
}

fn readNote(
    _: *Self,
    note: State.Item,
    printer: *Printer,
) !void {
    const content = try note.Note.read();
    try printer.addHeading("", .{});
    _ = try printer.addLine("{s}", .{content});
}

fn readDay(
    self: *Self,
    day: State.Item,
    printer: *Printer,
) !void {
    const entries = try day.Day.journal.readEntries(day.Day.day);

    if (!self.filename) {
        try printer.addHeading("Journal entry: {s}\n\n", .{day.getName()});
        if (self.full_date) {
            _ = try printer.addItems(entries, printEntryFullTime);
        } else {
            _ = try printer.addItems(entries, printEntryItem);
        }
    } else {
        try printer.addHeading("", .{});
        var capture: FilenameClosure = .{ .filename = day.getPath() };
        _ = try printer.addItemsCtx(
            FilenameClosure,
            entries,
            printEntryItemFilename,
            capture,
        );
    }
}

fn readJournal(
    self: *Self,
    journal: *State.Collection,
    printer: *Printer,
) !void {
    var alloc = printer.mem.allocator();
    var day_list = try journal.getAll(alloc);

    if (day_list.len == 0) {
        try printer.addHeading("-- Empty --\n", .{});
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
        try self.readDay(day, printer);
        if (!printer.couldFit(1)) break;
    }
    printer.reverse();
}

fn printEntryItem(writer: Printer.Writer, entry: Entry) Printer.WriteError!void {
    const date = utils.dateFromMs(entry.created);
    const time_of_day = utils.formatTimeBuf(date) catch
        return Printer.WriteError.DateError;

    try writer.print("{s} | {s}\n", .{ time_of_day, entry.item });
}

fn printEntryFullTime(writer: Printer.Writer, entry: Entry) Printer.WriteError!void {
    const date = utils.dateFromMs(entry.created);
    const time = utils.formatDateTimeBuf(date) catch
        return Printer.WriteError.DateError;

    try writer.print("{s} | {s}\n", .{ time, entry.item });
}

const FilenameClosure = struct { filename: []const u8 };
fn printEntryItemFilename(
    fc: FilenameClosure,
    writer: Printer.Writer,
    entry: Entry,
) Printer.WriteError!void {
    const date = utils.dateFromMs(entry.created);
    const time_of_day = utils.formatTimeBuf(date) catch
        return Printer.WriteError.DateError;
    try writer.print(
        "{s} {s} - {s}\n",
        .{ fc.filename, time_of_day, entry.item },
    );
}

fn readTask(
    _: *Self,
    task: State.Item,
    printer: *Printer,
) !void {
    comptime var cham = Chameleon.init(.Auto);
    const t = task.Task.task;
    const status = t.status(utils.Date.now());

    const due_s = if (t.due) |due|
        &try utils.formatDateTimeBuf(utils.dateFromMs(due))
    else
        "null";

    const completed_s = if (t.completed) |compl|
        &try utils.formatDateTimeBuf(utils.dateFromMs(compl))
    else
        "not completed";

    try printer.addHeading("Task        :   {s}\n\n", .{t.title});

    _ = try printer.addInfoLine(
        null,
        "Created",
        null,
        "  {s}\n",
        .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.created))},
    );

    _ = try printer.addInfoLine(
        null,
        "Modified",
        null,
        "  {s}\n",
        .{&try utils.formatDateTimeBuf(utils.dateFromMs(t.modified))},
    );

    _ = try printer.addInfoLine(
        null,
        "Due",
        switch (status) {
            .Done => cham.dim(),
            .PastDue => cham.bold().redBright(),
            .NearlyDue => cham.yellow(),
            else => null,
        },
        "  {s}\n",
        .{due_s},
    );

    _ = try printer.addInfoLine(
        null,
        "Importance",
        switch (t.importance) {
            .high => cham.yellow(),
            .low => cham.dim(),
            .urgent => cham.bold().redBright(),
        },
        "{s}\n",
        .{switch (t.importance) {
            .low => "  Low",
            .high => "* High",
            .urgent => "! Urgent",
        }},
    );

    _ = try printer.addInfoLine(
        null,
        "Completed",
        switch (status) {
            .Done => cham.greenBright(),
            else => cham.dim(),
        },
        "  {s}\n",
        .{completed_s},
    );

    _ = try printer.addLine("\n", .{});
    _ = try printer.addFormattedLine(cham.underline(), "Details:", .{});
    _ = try printer.addLine("\n", .{});
    _ = try printer.addLine("\n{s}", .{t.details});
}
