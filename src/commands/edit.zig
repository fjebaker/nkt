const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const notes = @import("../notes.zig");

const State = @import("../State.zig");
const Editor = @import("../Editor.zig");

const Self = @This();

pub const alias = [_][]const u8{"e"};

pub const help = "Edit a note with EDITOR.";
pub const extended_help =
    \\Edit a note with $EDITOR
    \\
    \\  nkt edit <name or day-like>
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt edit 0         # edit day today (day 0)
    \\  nkt edit 2023-1-1  # edit day 2023-1-1
    \\  nkt edit lldb      # edit notes labeled `lldb`
    \\
;

selection: notes.AnyNote,

pub fn init(itt: *cli.ArgIterator) !Self {
    var string: ?[]const u8 = null;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
        string = arg.string;
    }

    if (string) |s| {
        return .{ .selection = try notes.parse(s) };
    } else {
        return cli.CLIErrors.TooFewArguments;
    }
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const rel_path = try self.selection.getRelPath(state);
    const abs_path = try state.absPathify(rel_path);

    if (try state.fs.fileExists(rel_path)) {
        try out_writer.print("Opening file '{s}'\n", .{rel_path});
    } else {
        try out_writer.print("Creating new file '{s}'\n", .{rel_path});
        try self.selection.makeTemplate(state, rel_path);
    }

    var editor = try Editor.init(state.mem.child_allocator);
    defer editor.deinit();

    try editor.editPath(abs_path);
}
