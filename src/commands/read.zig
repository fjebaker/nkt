const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Printer = @import("../Printer.zig");

const Self = @This();

pub const alias = [_][]const u8{"r"};

pub const help = "Display the contentes of notes in various ways";
pub const extended_help =
    \\Print the contents of a journal or note to stdout
    \\  nkt read
    \\     <what>                what to print: name of a journal, or a note
    \\                             entry. if choice is ambiguous, will print both,
    \\                             else specify with the `--journal` or `--dir`
    \\                             flags
    \\     -j/--journal name     name of journal to read from
    \\     -d/--director name    name of directory to read from
    \\     -n/--limit int        maximum number of entries to display (default: 25)
    \\     --all                 display all items (overwrites `--limit`)
    \\
;

selection: ?cli.Selection,
where: ?cli.SelectedCollection,
number: usize,
all: bool,

const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{
        .selection = null,
        .where = null,
        .number = 25,
        .all = false,
    };

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                self.all = true;
            } else if (try parseCollection(arg, itt, true)) |col| {
                if (self.where != null) return cli.SelectionError.AmbiguousSelection;
                self.where = col;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
            self.selection = try cli.Selection.parse(arg.string);
        }
    }

    return self;
}

const NoSuchCollection = State.Collection.Errors.NoSuchCollection;

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const N = if (self.all) null else self.number;
    var printer = Printer.init(state.allocator, N);
    defer printer.deinit();

    if (self.selection) |selection| {
        // if selection is specified
        var selected = cli.find(state, self.where, selection) orelse
            return NoSuchCollection;
        // ensure note has been read from file
        try selected.ensureContent();

        switch (selected) {
            .JournalEntry => |journal_entry| {
                try self.readJournalEntry(journal_entry.item, &printer);
            },
            .DirectoryJournalItems => |both| {
                try self.readNote(both.directory.item, &printer);
                try self.readJournalEntry(both.journal.item, &printer);
            },
            .Note => |note_directory| {
                try self.readNote(note_directory.item, &printer);
            },
        }
    } else if (self.where) |w| switch (w.container) {
        // if no selection, but a collection
        .Journal => {
            const journal = state.getJournal(w.name) orelse
                return NoSuchCollection;
            try self.readJournal(journal, &printer);
        },
        else => {},
    } else {
        // default behaviour
        const journal = state.getJournal("diary").?;
        try self.readJournal(journal, &printer);
    }

    try printer.drain(out_writer);
}

fn readJournal(
    self: *Self,
    journal: *State.Journal,
    printer: *Printer,
) !void {
    var alloc = printer.mem.allocator();
    var entry_list = try journal.getChildList(alloc);

    if (entry_list.items.len == 0) {
        try printer.addHeading("-- Empty --\n", .{});
        return;
    }

    entry_list.sortBy(.Created);
    entry_list.reverse();

    var line_count: usize = 0;
    const last = for (0.., entry_list.items) |i, *item| {
        try journal.readChildContent(item);
        const N = item.children.?.len;
        line_count += N;
        if (!printer.couldFit(line_count)) {
            break i;
        }
    } else entry_list.items.len -| 1;

    printer.reverse();
    for (entry_list.items[0 .. last + 1]) |entry| {
        try self.readJournalEntry(entry, printer);
        if (!printer.couldFit(1)) break;
    }
    printer.reverse();
}

fn printEntryItem(writer: Printer.Writer, item: State.Journal.Child.Item) Printer.WriteError!void {
    const date = utils.Date.initUnixMs(item.created);
    const time_of_day = utils.formatTimeBuf(date) catch return Printer.WriteError.DateError;
    try writer.print("{s} - {s}\n", .{ time_of_day, item.item });
}

fn readJournalEntry(
    _: *Self,
    entry: State.Journal.Child,
    printer: *Printer,
) !void {
    try printer.addHeading("Journal entry: {s}\n\n", .{entry.info.name});
    _ = try printer.addItems(entry.children, printEntryItem);
}

fn readNote(
    _: *Self,
    note: State.Directory.Child,
    printer: *Printer,
) !void {
    try printer.addHeading("", .{});
    _ = try printer.addLine("{s}", .{note.children.?});
}
