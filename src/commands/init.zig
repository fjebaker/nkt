const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

pub const help = "(Re)Initialize the home directory structure.";

const Self = @This();

pub fn init(itt: *cli.ArgIterator) !Self {
    if (try itt.next()) |_| return cli.CLIErrors.TooManyArguments;
    return .{};
}

pub fn run(
    _: *Self,
    _: std.mem.Allocator,
    _: anytype,
    state: *State,
) !void {
    try state.setupDirectory();
}
