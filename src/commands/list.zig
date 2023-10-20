const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const notes = @import("../notes.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const alias = [_][]const u8{"ls"};

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list 
    \\     [-n/--limit int]      maximum number of entries to display
    \\     [notes|days]          list either notes or days (default days)
    \\
;

const Options = enum { notes, days };

selection: Options,
number: usize,

pub fn init(itt: *cli.ArgIterator) !Self {
    var selection: ?Options = null;
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
            if (selection == null) {
                if (std.meta.stringToEnum(Options, arg.string)) |s| {
                    selection = s;
                }
            } else return cli.CLIErrors.TooManyArguments;
        }
    }
    return .{
        .selection = selection orelse .days,
        .number = number,
    };
}

fn writeDiary(
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

fn listNotes(
    self: Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    _ = self;
    _ = alloc;
    _ = out_writer;
    _ = state;
    // todo
}

fn listDays(
    self: Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    var daylist = try DayEntry.getDayList(alloc, state);
    defer daylist.deinit();

    daylist.sort();

    const end = @min(self.number, daylist.days.len);
    try out_writer.print("Last {d} diary entries:\n", .{end});
    for (1.., daylist.days[0..end]) |i, date| {
        var day = try utils.formatDate(alloc, date);
        defer alloc.free(day);
        try out_writer.print("{d}: {s}\n", .{ end - i, day });
    }
}

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    switch (self.selection) {
        .notes => try self.listNotes(alloc, out_writer, state),
        .days => try self.listDays(alloc, out_writer, state),
    }
}
