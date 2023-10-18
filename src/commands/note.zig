const std = @import("std");
const cli = @import("../cli.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const help = "Quickly add a note to today's store from the command line";

note: []const u8,

pub fn init(itt: *cli.ArgIterator) !Self {
    const note = (try itt.next()) orelse
        return cli.CLIErrors.TooFewArguments;
    if (note.flag) return cli.CLIErrors.UnknownFlag;
    return .{ .note = note.string };
}

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    var day = try DayEntry.today(alloc, state);
    defer day.deinit();

    try day.addNote(self.note);
    try day.writeMeta();

    try out_writer.print("Written note to '{s}'\n", .{day.meta_filepath});
}
