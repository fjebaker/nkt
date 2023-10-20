const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const notes = @import("../notes.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const alias = [_][]const u8{"r"};

pub const help = "Display the contentes of notes in various ways";
pub const extended_help =
    \\Print the note to stdout in a formatted way.
    \\  nkt read
    \\     [-n/--limit int]      maximum number of entries to display
    \\     [note or day-like]    print
    \\Without any arguments, default to printing last `--limit` notes.
    \\
;

selection: ?notes.Note,
number: usize,

pub fn init(itt: *cli.ArgIterator) !Self {
    const selection = try notes.optionalParse(itt);
    var number: usize = 25;

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                number = try value.as(usize);
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            return cli.CLIErrors.TooManyArguments;
        }
    }

    return .{ .selection = selection, .number = number };
}

fn readDiary(
    out_writer: anytype,
    entry: DayEntry,
    limit: usize,
) !void {
    try out_writer.print("Notes for {s}\n", .{try utils.formatDateBuf(entry.date)});

    const offset = @min(entry.notes.len, limit);
    const start = entry.notes.len - offset;

    for (entry.notes[start..]) |note| {
        const time_of_day = utils.adjustTimezone(utils.Date.initUnixMs(note.modified));
        try time_of_day.format("HH:mm:ss - ", .{}, out_writer);
        try out_writer.print("{s}\n", .{note.content});
    }
}

fn readLastNotes(
    self: Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    var mem = std.heap.ArenaAllocator.init(alloc);
    defer mem.deinit();
    var temp_alloc = mem.allocator();

    var dl = try DayEntry.getDayList(temp_alloc, state);
    dl.sort();

    // calculate how many diary entries we need
    var list = std.ArrayList(DayEntry).init(temp_alloc);
    var note_count: usize = 0;
    for (0..dl.days.len) |i| {
        const date = dl.days[dl.days.len - i - 1];
        var diary = try DayEntry.openDate(temp_alloc, date, state);
        try list.append(diary);
        note_count += diary.notes.len;
        if (note_count >= self.number) break;
    }

    std.mem.reverse(DayEntry, list.items);

    // print the first one truncated
    const difference = note_count -| self.number;
    try readDiary(out_writer, list.items[0], list.items[0].notes.len - difference);

    // print the rest
    if (list.items.len > 1) {
        for (list.items[1..]) |diary| {
            try readDiary(out_writer, diary, note_count);
            note_count -|= diary.notes.len;
        }
    }
}

fn readEntry(
    self: Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    var note = self.selection.?;
    const date = try note.getDate(alloc, state);
    var diary = try DayEntry.openDate(alloc, date, state);
    defer diary.deinit();
    try readDiary(out_writer, diary, self.number);
}

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    if (self.selection) |selection| switch (selection) {
        .Day, .Date => try self.readEntry(alloc, out_writer, state),
        .Name => {},
    } else {
        try self.readLastNotes(alloc, out_writer, state);
    }
}
