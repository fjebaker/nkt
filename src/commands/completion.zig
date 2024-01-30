const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const Commands = @import("../main.zig").Commands;

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{ "r", "rp" };

pub const help = "zsh completion helper";

const Mode =
    enum { Listing, Prefixed, Zsh };
mode: Mode,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var mode: ?Mode = null;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "listing")) {
                if (mode != null) return cli.CLIErrors.InvalidFlag;
                mode = .Listing;
            } else if (arg.is(null, "prefixed")) {
                if (mode != null) return cli.CLIErrors.InvalidFlag;
                mode = .Prefixed;
            } else if (arg.is(null, "zsh")) {
                if (mode != null) return cli.CLIErrors.InvalidFlag;
                mode = .Zsh;
            }
        } else return cli.CLIErrors.TooManyArguments;
    }

    if (mode == null) return cli.CLIErrors.NoValueGiven;

    return .{ .mode = mode.? };
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    switch (self.mode) {
        .Listing => {
            for (state.directories) |*dir| {
                // skip the diary for now
                if (std.mem.eql(u8, dir.getName(), "diary")) {
                    continue;
                }
                try listDirContentsPrefixed(
                    state.allocator,
                    out_writer,
                    dir,
                    "",
                );
            }
        },
        .Prefixed => {
            for (state.directories) |*dir| {
                const prefix = try std.fmt.allocPrint(state.allocator, "{s}.", .{dir.getName()});
                defer state.allocator.free(prefix);
                try listDirContentsPrefixed(
                    state.allocator,
                    out_writer,
                    dir,
                    prefix,
                );
            }
        },
        .Zsh => {
            try printZshCompletionFile(state.allocator, out_writer);
        },
    }
}

fn listDirContentsPrefixed(
    alloc: std.mem.Allocator,
    writer: anytype,
    directory: *State.Collection,
    prefix: []const u8,
) !void {
    const notelist = try directory.getAll(alloc);
    defer alloc.free(notelist);
    for (notelist) |note| {
        try writer.print("{s}{s} ", .{ prefix, note.getName() });
    }
}

fn listCommandHelp(
    alloc: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    var writer = buf.writer();

    inline for (@typeInfo(Commands).Union.fields) |field| {
        if (!std.mem.eql(u8, field.name, "completion")) {
            const help_text = @field(field.type, "help");
            try writer.print("'{s}:{s}' ", .{ field.name, help_text });
        }
    }

    return buf.toOwnedSlice();
}

fn printZshCompletionFile(alloc: std.mem.Allocator, writer: anytype) !void {
    var mem = std.heap.ArenaAllocator.init(alloc);
    defer mem.deinit();
    const allocator = mem.allocator();
    _ = try writer.writeAll(
        \\#compdef _nkt nkt
        \\
        \\_nkt() {
        \\    local line state
        \\    _arguments -C \
        \\               "1: :->cmds" \
        \\               "2::arg:->args"
        \\
        \\    case "$state" in
        \\        cmds)
        \\
    );
    const command_descriptions = try listCommandHelp(allocator);
    try writer.print(
        \\            subcmds=({s})
        \\            _describe 'command' subcmds
        \\
    ,
        .{command_descriptions},
    );
    _ = try writer.writeAll(
        \\            ;;
        \\
        \\        args)
        \\            case $line[1] in
        \\                edit|e|r|rp|read)
        \\                    _list_note_options
        \\                    ;;
        \\                ls|list|fe|find|fr|fp)
        \\                    _list_prefixed_options
        \\                    ;;
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\
        \\_list_note_options() {
        \\    compadd $(nkt completion --listing)
        \\}
        \\_list_prefixed_options() {
        \\    compadd $(nkt completion --prefixed)
        \\}
        \\
    );
}
