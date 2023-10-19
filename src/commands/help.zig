const std = @import("std");
const cli = @import("../cli.zig");

const Commands = @import("../main.zig").Commands;
const CommandError = @import("../main.zig").CommandError;
const State = @import("../State.zig");

const Self = @This();

pub const help = "Print this help message.";

command: []const u8,

pub fn init(itt: *cli.ArgIterator) !Self {
    var command: []const u8 = "";

    if (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        command = arg.string;
    }

    return .{ .command = command };
}

pub fn printExtendedHelp(writer: anytype, command: []const u8) !void {
    var unknown_command = true;

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const has_extended_help = @hasDecl(field.type, "extended_help");
        const field_right = std.mem.eql(u8, field.name, command);

        if (has_extended_help and field_right) {
            const eh = @field(field.type, "extended_help");
            try writer.print("Extended help for {s}\n{s}", .{ command, eh });
            return;
        }

        if (field_right) unknown_command = false;
    }

    if (unknown_command) {
        return CommandError.UnknownCommand;
    }

    try writer.print("No extended help for '{s}' available.\n", .{command});
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll("Help:\n");

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const descr = @field(field.type, "help");
        try writer.print(" - {s: <11} {s}\n", .{ field.name, descr });
    }
}

pub fn run(
    self: *Self,
    _: std.mem.Allocator,
    out_writer: anytype,
    _: *State,
) !void {
    if (self.command.len > 0) {
        try printExtendedHelp(out_writer, self.command);
    } else {
        try printHelp(out_writer);
    }
}
