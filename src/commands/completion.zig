const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const arguments = cli.Arguments(&.{.{
    .arg = "--list collection",
    .help = "For internal use only.",
}});

pub const short_help = "Shell completion helper";
pub const long_help = short_help;

args: arguments.Parsed,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    return .{ .args = args };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();
    _ = opts;

    if (self.args.list) |collection| {
        if (std.mem.eql(u8, collection, "journal")) {
            for (root.info.journals) |c| {
                try writer.writeAll(c.name);
                try writer.writeAll(" ");
            }
        } else if (std.mem.eql(u8, collection, "directory")) {
            for (root.info.directories) |c| {
                try writer.writeAll(c.name);
                try writer.writeAll(" ");
            }
        } else if (std.mem.eql(u8, collection, "tasklist")) {
            for (root.info.tasklists) |c| {
                try writer.writeAll(c.name);
                try writer.writeAll(" ");
            }
        } else if (std.mem.eql(u8, collection, "chains")) {
            const chainlist = try root.getChainList();
            for (chainlist.chains) |c| {

                // try writer.print("\"{s}\" ", .{c.name});
                if (c.alias) |alias| {
                    try writer.writeAll(alias);
                    try writer.writeAll(" ");
                }
            }
        } else {
            try cli.throwError(error.UnknownSelection, "Invalid completion collection '{s}'", .{collection});
        }
    } else {
        try writeTemplate(allocator, writer);
    }
}

pub fn writeTemplate(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("#compdef _nkt nkt\n\n");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    var case_switches = std.ArrayList(u8).init(alloc);
    defer case_switches.deinit();

    var switch_writer = case_switches.writer();

    var all_commands = std.ArrayList(u8).init(alloc);
    defer all_commands.deinit();

    var all_writer = all_commands.writer();

    const info = @typeInfo(Commands).Union;
    inline for (info.fields) |field| {
        const name = field.name;
        const descr = @field(field.type, "short_help");
        const has_arguments = @hasDecl(field.type, "arguments");
        if (has_arguments) {
            const args = @field(field.type, "arguments");

            const cmpl = try args.generateCompletion(alloc, .Zsh, name);
            defer alloc.free(cmpl);
            try writer.writeAll(cmpl);

            try switch_writer.print(
                \\        {s})
                \\            _arguments_{s}
                \\        ;;
                \\
            , .{ name, name });
        }

        const escp_descr = try std.mem.replaceOwned(u8, alloc, descr, "'", "'\\''");
        try all_writer.print("        '{s}:{s}'\n", .{ name, escp_descr });
    }

    try writer.print(ZSH_TEMPLATE, .{ all_commands.items, case_switches.items });
}

const ZSH_TEMPLATE =
    \\_subcommands() {{
    \\    local -a commands
    \\    commands=(
    \\{s}        )
    \\    _describe 'command' commands
    \\}}
    \\
    \\_nkt() {{
    \\    local line state
    \\
    \\    _arguments \
    \\        '1:command:_subcommands' \
    \\        '*::arg:->args'
    \\
    \\    case $line[1] in
    \\{s}
    \\    esac
    \\}}
    \\
;
