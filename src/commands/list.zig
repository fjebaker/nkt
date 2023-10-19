const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const help = "List notes in various ways.";

const Options = enum { notes, days };

what: Options,

pub fn init(itt: *cli.ArgIterator) !Self {
    itt.counter = 0;
    var what: Options = .notes;
    while (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
        what = std.meta.stringToEnum(Options, arg.string) orelse return cli.CLIErrors.BadArgument;
    }
    return .{ .what = what };
}

fn listNotes(_: *const Self, alloc: std.mem.Allocator, out_writer: anytype, state: *State) !void {
    var day = try DayEntry.today(alloc, state);
    defer day.deinit();
    for (day.notes) |note| {
        const date = utils.Date.initUnixMs(note.modified + utils.timezone());
        try date.format("HH:mm:ss - ", .{}, out_writer);
        try out_writer.print("{s}\n", .{note.content});
    }
}

pub fn getDayList(state: *State) void {
    var dir = try state.getDir();
    var itdir = std.fs.IterableDir{ .dir = dir };
    _ = itdir;
}

fn listDays(_: *const Self, alloc: std.mem.Allocator, out_writer: anytype, state: *State) !void {
    _ = alloc;
    _ = out_writer;
    _ = state;
}

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    switch (self.what) {
        .notes => self.listNotes(self, alloc, out_writer, state),
        .days => self.listDays(self, alloc, out_writer, state),
    }
}
