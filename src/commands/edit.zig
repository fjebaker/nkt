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
    \\                             else specify with the collection flags
    \\     -n/--new              allow the creation of new notes
    \\
++ cli.Selection.COLLECTION_FLAG_HELP ++
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt edit 0         # edit day today (day 0)
    \\  nkt edit 2023-1-1  # edit day 2023-1-1
    \\  nkt edit lldb      # edit notes labeled `lldb`
    \\
;

selection: cli.Selection = .{},
allow_new: bool = false,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    itt.counter = 0;
    while (try itt.next()) |arg| {
        // parse selection
        if (try self.selection.parse(arg, itt)) continue;

        // handle other options
        if (arg.flag) {
            if (arg.is('n', "new")) {
                self.allow_new = true;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            return cli.CLIErrors.TooManyArguments;
        }
    }

    if (!self.selection.validate(.Item))
        return cli.CLIErrors.TooFewArguments;

    return self;
}

fn createDefaultInDirectory(
    self: *Self,
    state: *State,
) !State.Item {
    // guard against trying to use journal
    if (self.selection.collection) |w| if (w.container == .Journal)
        return cli.SelectionError.InvalidSelection;

    const default_dir: []const u8 = switch (self.selection.item.?) {
        .ByIndex => return cli.SelectionError.InvalidSelection,
        .ByDate => "diary",
        .ByName => "notes",
    };

    var dir: *State.Collection = blk: {
        if (self.selection.collection) |w| {
            break :blk state.getDirectory(w.name) orelse
                return cli.SelectionError.UnknownCollection;
        } else break :blk state.getDirectory(default_dir).?;
    };

    switch (self.selection.item.?) {
        .ByName => |name| return try dir.Directory.newNote(name),
        .ByIndex => unreachable,
        .ByDate => |date| {
            // format information about the day
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

fn findOrCreateDefault(self: *Self, state: *State) !struct {
    new: bool,
    item: State.MaybeItem,
} {
    const item: ?State.MaybeItem = try self.selection.find(state);

    if (item) |i| {
        if (i.numActive() == 1 and (i.getActive() catch unreachable) == .Day) {
            // need at least a note or a task
        } else {
            return .{ .new = false, .item = item.? };
        }
    }

    if (self.allow_new) {
        return .{
            .new = true,
            .item = .{
                .note = try createDefaultInDirectory(self, state),
            },
        };
    } else {
        return cli.SelectionError.NoSuchItem;
    }
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var iteminfo = try self.findOrCreateDefault(state);
    var item = iteminfo.item;

    if (item.note) |note| {
        const rel_path = note.getPath();

        const abs_path = try state.fs.absPathify(state.allocator, rel_path);
        defer state.allocator.free(abs_path);

        if (iteminfo.new) {
            try out_writer.print(
                "Creating new file '{s}' in '{s}'\n",
                .{ rel_path, note.collectionName() },
            );
        } else {
            try out_writer.print("Opening file '{s}'\n", .{rel_path});
        }

        var editor = try Editor.init(state.allocator);
        defer editor.deinit();

        try editor.editPath(abs_path);
        note.Note.note.modified = utils.now();
    } else if (item.task) |task| {
        var editor = try Editor.init(state.allocator);
        defer editor.deinit();

        var task_allocator = task.Task.tasklist.mem.allocator();
        const new_details = try editor.editTemporaryContent(
            task_allocator,
            task.Task.task.details,
        );

        task.Task.task.details = new_details;
        task.Task.task.modified = utils.now();

        try out_writer.print(
            "Task details for '{s}' in '{s}' updated\n",
            .{ task.getName(), task.collectionName() },
        );
    } else {
        return cli.SelectionError.InvalidSelection;
    }
}
