const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

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
    \\     [--journal name]      name of journal to read from
    \\     [--dir name]          name of directory to read from
    \\     [-n/--limit int]      maximum number of entries to display (default: 25)
    \\     [--all]               display all items (overwrites `--limit`)
    \\
;

selection: ?cli.Selection,
where: ?cli.SelectedCollection,
number: usize,
all: bool,

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
            } else if (arg.is(null, "journal")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(.Journal, value.string);
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(.Directory, value.string);
                }
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
    } else entry_list.items.len - 1;

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

const Printer = struct {
    const StringList = std.ArrayList(u8);

    fn ChildType(comptime T: anytype) type {
        const info = @typeInfo(T);
        if (info == .Optional) {
            return @typeInfo(info.Optional.child).Pointer.child;
        } else {
            return info.Pointer.child;
        }
    }

    pub const Writer = StringList.Writer;
    pub const WriteError = error{ OutOfMemory, DateError };
    pub const PrinterError = error{HeadingMissing};

    const Chunk = struct {
        heading: []const u8,
        lines: StringList,

        fn print(self: *Chunk, writer: anytype) !void {
            _ = try writer.writeAll(self.heading);
            _ = try writer.writeAll(try self.lines.toOwnedSlice());
        }
    };

    const ChunkList = std.ArrayList(Chunk);

    remaining: ?usize,
    mem: std.heap.ArenaAllocator,
    chunks: ChunkList,
    current: ?*Chunk = null,

    pub fn init(alloc: std.mem.Allocator, N: ?usize) Printer {
        var mem = std.heap.ArenaAllocator.init(alloc);
        errdefer mem.deinit();

        var list = ChunkList.init(alloc);

        return .{ .remaining = N, .chunks = list, .mem = mem };
    }

    pub fn drain(self: *const Printer, writer: anytype) !void {
        var chunks = self.chunks.items;
        // print first chunk
        if (chunks.len > 0) {
            try chunks[0].print(writer);
        }
        if (chunks.len > 1) {
            for (chunks[1..]) |*chunk| {
                _ = try writer.writeAll("\n");
                try chunk.print(writer);
            }
        }
    }

    fn subRemainder(self: *Printer, i: usize) bool {
        if (self.remaining == null) return true;
        self.remaining.? -= i;
        return self.remaining.? != 0;
    }

    fn allowMore(self: *const Printer) bool {
        if (self.remaining) |rem| {
            return rem > 0;
        }
        return true;
    }

    pub fn reverse(self: *Printer) void {
        std.mem.reverse(Chunk, self.chunks.items);
    }

    pub fn addItems(
        self: *Printer,
        items: anytype,
        comptime write_function: fn (writer: Writer, item: ChildType(@TypeOf(items))) WriteError!void,
    ) !bool {
        const _items = if (@typeInfo(@TypeOf(items)) == .Optional) items.? else items;
        var chunk = self.current orelse return PrinterError.HeadingMissing;

        var writer = chunk.lines.writer();

        const start = if (self.remaining) |rem|
            (_items.len -| rem)
        else
            0;

        for (_items[start..]) |item| {
            try write_function(writer, item);
        }

        return self.subRemainder(_items.len - start);
    }

    pub fn addLine(self: *Printer, comptime format: []const u8, args: anytype) !bool {
        var chunk = self.current orelse return PrinterError.HeadingMissing;

        if (self.allowMore()) {
            try chunk.lines.writer().print(format, args);
        }
        return self.subRemainder(1);
    }

    pub fn addHeading(self: *Printer, comptime format: []const u8, args: anytype) !void {
        var alloc = self.mem.allocator();

        var heading_writer = StringList.init(alloc);
        var lines = StringList.init(alloc);

        try heading_writer.writer().print(format, args);

        var chunk: Chunk = .{
            .heading = try heading_writer.toOwnedSlice(),
            .lines = lines,
        };
        try self.chunks.append(chunk);

        self.current = &self.chunks.items[self.chunks.items.len - 1];
    }

    pub fn deinit(self: *Printer) void {
        self.chunks.deinit();
        self.mem.deinit();
        self.* = undefined;
    }

    pub fn couldFit(self: *Printer, size: usize) bool {
        if (self.remaining) |rem| {
            return rem >= size;
        }
        return true;
    }
};
