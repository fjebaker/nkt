const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const help = "Print this help message.";

pub const extended_help = cli.extendedHelp(
    &.{
        .{ .arg = "[command]", .help = "Subcommand to print extended help for." },
    },
    .{ .description = "Print help messages and additional information about subcommands." },
);

command: ?[]const u8,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var command: ?[]const u8 = null;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            try itt.throwUnknownFlag();
        }
        if (command == null) {
            command = arg.string;
        } else {
            try itt.throwTooManyArguments();
        }
    }
    return .{ .command = command };
}

pub fn run(
    self: *Self,
    _: *Root,
    out_writer: anytype,
    _: cli.Options,
) !void {
    if (self.command) |command| {
        try printExtendedHelp(out_writer, command);
    } else {
        try printHelp(out_writer);
    }
}

pub fn printExtendedHelp(writer: anytype, command: []const u8) !void {
    var unknown_command = true;

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const has_extended_help = @hasDecl(field.type, "extended_help");
        const field_right =
            std.mem.eql(u8, field.name, command) or utils.isAlias(field, command);

        if (has_extended_help and field_right) {
            const eh = @field(field.type, "extended_help");
            try writer.print("Extended help for {s}:\n\n", .{field.name});

            if (@hasDecl(field.type, "alias")) {
                _ = try writer.writeAll("Aliases:");
                for (@field(field.type, "alias")) |alias| {
                    try writer.print(" {s}", .{alias});
                }
                _ = try writer.writeAll("\n\n");
            }

            _ = try writer.writeAll(eh);
            return;
        }

        if (field_right) unknown_command = false;
    }

    if (unknown_command) {
        return commands.Error.UnknownCommand;
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
