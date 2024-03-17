const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "Print this help message or help for other commands.";
pub const long_help =
    \\Print help messages and additional information about subcommands.
;
pub const arguments = cli.Arguments(&.{
    .{
        .arg = "command",
        .help = "Subcommand to print extended help for.",
    },
});

command: ?[]const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);

    if (args.command) |cmd| {
        const command = toValidCommand(cmd) orelse {
            try cli.throwError(
                cli.CLIErrors.BadArgument,
                "help: no such command: '{s}'",
                .{cmd},
            );
            unreachable;
        };
        return .{ .command = command };
    }
    return .{ .command = null };
}

pub fn execute(
    self: *Self,
    _: std.mem.Allocator,
    _: *Root,
    out_writer: anytype,
    _: commands.Options,
) !void {
    if (self.command) |command| {
        try printExtendedHelp(out_writer, command);
    } else {
        try printHelp(out_writer);
    }
}

fn toValidCommand(command: []const u8) ?[]const u8 {
    // assert the argument is valid
    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const is_field = std.mem.eql(u8, command, field.name);
        const is_alias = utils.isAlias(field, command);
        if (is_field or is_alias) return field.name;
    }
    return null;
}

fn printExtendedHelp(
    writer: anytype,
    command: []const u8,
) !void {
    var unknown_command = true;

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const has_long_help = @hasDecl(field.type, "long_help");
        if (!has_long_help) {
            @compileError("Subcommand " ++ field.name ++ " needs to define `long_help`");
        }

        const has_arguments = @hasDecl(field.type, "arguments");
        const field_correct =
            std.mem.eql(u8, field.name, command) or utils.isAlias(field, command);

        if (field_correct) {
            try writer.print("Extended help for '{s}':\n\n", .{field.name});

            const long = comptime cli.comptimeWrap(
                @field(field.type, "long_help"),
                .{},
            );
            try writer.writeAll(long);
            try writer.writeAll("\n\n");

            if (@hasDecl(field.type, "alias")) {
                try writer.writeAll("Aliases:");
                for (@field(field.type, "alias")) |alias| {
                    try writer.print(" {s}", .{alias});
                }
                try writer.writeAll("\n\n");
            }

            if (has_arguments) {
                const args = @field(field.type, "arguments");
                try writer.writeAll("Arguments:\n\n");
                try args.writeHelp(writer, .{});
            }
            try writer.writeByte('\n');
            return;
        }

        if (field_correct) unknown_command = false;
    }

    if (unknown_command) {
        return commands.Error.UnknownCommand;
    }

    try writer.print("No extended help for '{s}' available.\n", .{command});
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll("Quick command reference:\n");

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const descr = @field(field.type, "short_help");
        try writer.print(" - {s: <11} {s}\n", .{ field.name, descr });
    }
}
