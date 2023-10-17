const std = @import("std");
const cli = @import("../cli.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../main.zig").State;

const Self = @This();

pub const help = "Print this help message.";

pub fn init(_: *cli.ArgIterator) !Self {
    return .{};
}

pub fn print_help(writer: anytype) !void {
    try writer.writeAll("Help:\n");
    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const descr = @field(field.type, "help");
        try writer.print(" - {s: <11} {s}\n", .{ field.name, descr });
    }
}

pub fn run(
    _: *Self,
    _: std.mem.Allocator,
    out_writer: anytype,
    _: *State,
) !void {
    try print_help(out_writer);
}
