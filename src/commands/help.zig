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
pub const arguments = cli.ArgumentsHelp(&.{
    .{
        .arg = "command",
        .help = "Subcommand to print extended help for.",
    },
}, .{});

command: ?[]const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    if (args.command) |cmd| {
        if (!isValidCommand(cmd)) {
            try cli.throwError(
                cli.CLIErrors.BadArgument,
                "help: no such command: '{s}'",
                .{cmd},
            );
        }
    }

    return .{ .command = args.command };
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

fn isValidCommand(command: []const u8) bool {
    // assert the argument is valid
    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field.name, command)) return true;
    }
    return false;
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
                if (args.arguments.len > 0) {
                    try writer.writeAll("Arguments:\n\n");
                    try args.writeHelp(writer);
                }
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
    try writer.writeAll("Help:\n");

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const descr = @field(field.type, "short_help");
        try writer.print(" - {s: <11} {s}\n", .{ field.name, descr });
    }
}
