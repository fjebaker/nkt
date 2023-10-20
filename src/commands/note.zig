const std = @import("std");
const cli = @import("../cli.zig");
const diary = @import("../diary.zig");

const State = @import("../State.zig");

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
    state: *State,
    out_writer: anytype,
) !void {
    var entry = try diary.today(state);
    defer entry.deinit();

    try entry.addNote(self.note);
    try entry.writeNotes(state);

    try out_writer.print("Written note to '{s}'\n", .{entry.notes_path});
}
