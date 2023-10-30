const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Editor = @import("../Editor.zig");

const Self = @This();

pub const alias = [_][]const u8{"e"};

pub const help = "Edit a note with EDITOR.";
pub const extended_help =
    \\Edit a note with $EDITOR
    \\
    \\  nkt edit
    \\     <what>                what to print: name of a journal, or a note
    \\                             entry. if choice is ambiguous, will print both,
    \\                             else specify with the `--journal` or `--dir`
    \\                             flags
    \\     --journal name        name of journal to read from
    \\     --dir name            name of directory to read from
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt edit 0         # edit day today (day 0)
    \\  nkt edit 2023-1-1  # edit day 2023-1-1
    \\  nkt edit lldb      # edit notes labeled `lldb`
    \\
;

selection: ?cli.Selection,
where: ?cli.SelectedCollection,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{ .selection = null, .where = null };

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "journal")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(.Journal, value.string);
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(.Directory, value.string);
                }
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
            self.selection = try cli.Selection.parse(arg.string);
        }
    }

    if (self.selection == null) return cli.CLIErrors.TooFewArguments;
    return self;
}

fn createDefaultInDirectory(
    self: *Self,
    state: *State,
) !State.Item {
    // guard against trying to use journal
    if (self.where) |w| if (w.container == .Journal)
        return cli.SelectionError.InvalidSelection;

    const selection = self.selection.?;

    const default_dir: []const u8 = switch (selection) {
        .ByIndex => return cli.SelectionError.InvalidSelection,
        .ByDate => "diary",
        .ByName => "notes",
    };

    var dir: *State.Collection = blk: {
        if (self.where) |w| {
            break :blk state.getDirectory(w.name) orelse
                return cli.SelectionError.UnknownCollection;
        } else break :blk state.getDirectory(default_dir).?;
    };

    switch (selection) {
        .ByName => |name| return try dir.Directory.newNote(name),
        .ByIndex => unreachable,
        .ByDate => {
            // format information about the day
            const date = selection.ByDate;
            const date_string = try utils.formatDateBuf(date);

            const day = try utils.dayOfWeek(state.allocator, date);
            defer state.allocator.free(day);
            const month = try utils.monthOfYear(state.allocator, date);
            defer state.allocator.free(month);

            // create the new item
            var note = try dir.Directory.newNote(&date_string);

            // write the template
            const template = try std.fmt.allocPrint(
                state.allocator,
                "# {s}: {s} of {s}\n\n",
                .{ date_string, day, month },
            );
            defer state.allocator.free(template);

            try state.fs.overwrite(note.getPath(), template);
            return note;
        },
    }
}

fn findOrCreateDefault(self: *Self, state: *State) !State.Item {
    const selection = self.selection.?;

    const item: State.MaybeItem = cli.find(
        state,
        self.where,
        selection,
    ) orelse
        return try createDefaultInDirectory(self, state);

    return item.note orelse
        try createDefaultInDirectory(self, state);
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var note = try self.findOrCreateDefault(state);
    const rel_path = note.getPath();

    const abs_path = try state.fs.absPathify(state.allocator, rel_path);
    defer state.allocator.free(abs_path);

    if (try state.fs.fileExists(rel_path)) {
        try out_writer.print("Opening file '{s}'\n", .{rel_path});
    } else {
        try out_writer.print("Creating new file '{s}'\n", .{rel_path});
    }

    var editor = try Editor.init(state.allocator);
    defer editor.deinit();

    try editor.editPath(abs_path);
    note.Note.note.modified = utils.now();
}
