const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const Commands = @import("../main.zig").Commands;

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{ "r", "rp" };

pub const help = "zsh completion helper";

const What = enum { journals, directories, notes, zsh };

what: What,
where: ?cli.SelectedCollection = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const what_arg = (try itt.next()) orelse return cli.CLIErrors.TooFewArguments;
    var self: Self = .{
        .what = std.meta.stringToEnum(What, what_arg.string) orelse
            return cli.CLIErrors.BadArgument,
    };
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    switch (self.what) {
        .notes => {
            for (state.directories) |*dir| {
                try listDirContents(state.allocator, out_writer, dir);
            }
        },
        .journals, .directories => {
            var cnames = try state.getCollectionNames(state.allocator);
            defer cnames.deinit();
            const what: State.CollectionType = switch (self.what) {
                .journals => .Journal,
                .directories => .Directory,
                else => unreachable,
            };
            try @import("list.zig").listNames(cnames, what, out_writer, .{ .oneline = true });
        },
        .zsh => {
            try printZshCompletionFile(state.allocator, out_writer);
        },
    }
}

fn listDirContents(alloc: std.mem.Allocator, writer: anytype, directory: *State.Collection) !void {
    var notelist = try directory.getAll(alloc);
    defer alloc.free(notelist);

    for (notelist) |note| {
        try writer.print("{s} ", .{note.getName()});
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
    var allocator = mem.allocator();
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
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\
        \\_list_note_options() {
        \\    compadd $(nkt completion notes)
        \\}
        \\
        \\_table_cmd() {
        \\    _arguments '(--tablearg)--tablearg[a value]' \
        \\               '(--tablearg2)--tablearg2[a value]'
        \\}
        \\
    );
}
