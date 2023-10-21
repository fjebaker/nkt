const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../NewState.zig");
const Topology = @import("../Topology.zig");

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

const Selection = cli.selections.Selection;
const ContainerSelection = cli.selections.ContainerSelection;

selection: ?Selection,
where: ?ContainerSelection,
number: usize,
all: bool,

pub fn init(itt: *cli.ArgIterator) !Self {
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
                    self.where = ContainerSelection.from(.Journal, value.string);
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = ContainerSelection.from(.Directory, value.string);
                }
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
            self.selection = try Selection.parse(arg.string);
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
        const collection = cli.selections.find(state, self.where, selection) orelse
            return NoSuchCollection;

        switch (collection) {
            .JournalEntry => |journal_entry| {
                try self.readJournalEntry(journal_entry.item, &printer);
            },
            .NoteWithJournalEntry => |both| {
                try self.readJournalEntry(both.journal.item, &printer);
            },
            else => {},
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
    journal: *State.TrackedJournal,
    printer: *Printer,
) !void {
    var alloc = printer.mem.allocator();
    var entry_list = try journal.getDatedEntryList(alloc);

    entry_list.sortBy(.Created);
    entry_list.reverse();

    var line_count: usize = 0;
    const last = for (0.., entry_list.items) |i, item| {
        const N = item.entry.items.len;
        line_count += N;
        if (!printer.couldFit(line_count)) {
            break i;
        }
    } else entry_list.items.len - 1;

    printer.reverse();
    for (entry_list.items[0 .. last + 1]) |entry| {
        try self.readJournalEntry(entry.entry, printer);
        if (!printer.couldFit(1)) break;
    }
    printer.reverse();
}

fn printEntryItem(writer: Printer.Writer, item: Topology.Journal.Entry.Item) Printer.WriteError!void {
    const date = utils.Date.initUnixMs(item.created);
    const time_of_day = utils.formatTimeBuf(date) catch return Printer.WriteError.DateError;
    try writer.print("{s} - {s}\n", .{ time_of_day, item.item });
}

fn readJournalEntry(
    _: *Self,
    entry: *const Topology.Journal.Entry,
    printer: *Printer,
) !void {
    try printer.addHeading("Journal entry: {s}\n\n", .{entry.name});
    _ = try printer.addItems(entry.items, printEntryItem);
}

const Printer = struct {
    const StringList = std.ArrayList(u8);

    fn ChildType(comptime T: anytype) type {
        return @typeInfo(T).Pointer.child;
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
        var chunk = self.current orelse return PrinterError.HeadingMissing;

        var writer = chunk.lines.writer();

        const start = if (self.remaining) |rem|
            (items.len -| rem)
        else
            0;

        for (items[start..]) |item| {
            try write_function(writer, item);
        }

        return self.subRemainder(items.len - start);
    }

    pub fn addLine(self: *Printer, comptime format: []const u8, args: anytype) !bool {
        var chunk = self.current orelse return PrinterError.HeadingMissing;

        if (self.allowMore()) {
            chunk.lines.writer().print(format, args);
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

// fn readDiary(
//     entry: notes.diary.Entry,
//     out_writer: anytype,
//     limit: usize,
// ) !void {
//     try out_writer.print("Notes for {s}\n", .{try utils.formatDateBuf(entry.date)});

//     const offset = @min(entry.notes.len, limit);
//     const start = entry.notes.len - offset;

//     for (entry.notes[start..]) |note| {
//         const time_of_day = utils.adjustTimezone(utils.Date.initUnixMs(note.modified));
//         try time_of_day.format("HH:mm:ss - ", .{}, out_writer);
//         try out_writer.print("{s}\n", .{note.content});
//     }
// }

// fn readDiaryContent(
//     state: *State,
//     entry: *notes.diary.Entry,
//     out_writer: anytype,
// ) !void {
//     try out_writer.print(
//         "Diary entry for {s}\n",
//         .{try utils.formatDateBuf(entry.date)},
//     );

//     const content = try entry.readDiary(state);
//     _ = try out_writer.writeAll(content);
// }

// fn readLastNotes(
//     self: Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     var alloc = state.mem.allocator();

//     var date_list = try list.getDiaryDateList(state);
//     defer date_list.deinit();

//     date_list.sort();

//     // calculate how many diary entries we need
//     var needed = std.ArrayList(*notes.diary.Entry).init(alloc);
//     var note_count: usize = 0;
//     for (0..date_list.items.len) |i| {
//         const date = date_list.items[date_list.items.len - i - 1];

//         var entry = try state.openDiaryEntry(date);
//         try needed.append(entry);

//         // tally how many entries we'd print now
//         note_count += entry.notes.len;
//         if (note_count >= self.number) break;
//     }

//     std.mem.reverse(*notes.diary.Entry, needed.items);

//     // print the first one truncated
//     const difference = note_count -| self.number;
//     try readDiary(needed.items[0].*, out_writer, needed.items[0].notes.len - difference);

//     // print the rest
//     if (needed.items.len > 1) {
//         for (needed.items[1..]) |entry| {
//             try readDiary(entry.*, out_writer, note_count);
//             note_count -|= entry.notes.len;
//         }
//     }
// }

// fn readNamedNode(self: Self, state: *State, out_writer: anytype) !void {
//     var note = self.selection.?;
//     const rel_path = try note.getRelPath(state);

//     if (try state.fs.fileExists(rel_path)) {
//         var content = try state.fs.readFileAlloc(state.mem.allocator(), rel_path);
//         _ = try out_writer.writeAll(content);
//     } else {
//         return notes.NoteError.NoSuchNote;
//     }
// }

// fn readEntry(
//     self: Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     var note = self.selection.?;
//     const date = try note.getDate(state);

//     var entry = try state.openDiaryEntry(date);

//     if (entry.has_diary) try readDiaryContent(
//         state,
//         entry,
//         out_writer,
//     );
//     try readDiary(entry.*, out_writer, self.number);
// }
