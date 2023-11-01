const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{"rm"};

pub const help = "Remove a note from a directory, an entry from a journal, or an item from an entry.";
pub const extended_help =
    \\Remove a note from a directory, an entry from a journal, or an item 
    \\from an entry.
    \\  nkt remove
    \\     --collection <type>   remove full collection instead of child of 
    \\                           collection (default: false)
    \\     <what>                what to remove: name of a journal entry, or a note.
    \\                             if choice is ambiguous, will fail unless
    \\                             specified with the `--journal` or `--dir`
    \\                             flags. for removing items from an entry,
    \\                             specify the time stamp with `--time`
    \\     --time name           time of the item to remove from the chosen
    \\                            entry. must be specified in `hh:mm:ss`
    \\
++ cli.selections.COLLECTION_FLAG_HELP ++
    \\     -f                    don't prompt for removal
    \\
;

const RemoveChild = struct {
    selection: ?cli.Selection,
    where: ?cli.SelectedCollection,
    time: ?[]const u8,
};

selection: union(enum) {
    Child: RemoveChild,
    Collection: cli.SelectedCollection,
},

fn initChild(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{
        .selection = .{
            .Child = .{
                .selection = null,
                .where = null,
                .time = null,
            },
        },
    };
    var child = &self.selection.Child;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "time")) {
                const value = try itt.getValue();
                child.time = value.string;
            } else if (arg.is(null, "journal")) {
                if (child.where == null) {
                    const value = try itt.getValue();
                    child.where = cli.SelectedCollection.from(.Journal, value.string);
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (child.where == null) {
                    const value = try itt.getValue();
                    child.where = cli.SelectedCollection.from(.Directory, value.string);
                }
            } else if (arg.is(null, "tl") or arg.is(null, "tasklist")) {
                if (child.where == null) {
                    const value = try itt.getValue();
                    child.where = cli.SelectedCollection.from(.Tasklist, value.string);
                }
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
            child.selection = try cli.Selection.parse(arg.string);
        }
    }

    if (child.selection == null) return cli.CLIErrors.TooFewArguments;

    return self;
}

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    const arg = (try itt.next()) orelse return cli.CLIErrors.TooFewArguments;
    if (arg.flag and arg.is(null, "collection")) {
        const selection = try cli.selections.getSelectedCollectionPositional(itt);
        return .{ .selection = .{ .Collection = selection } };
    } else {
        itt.rewind();
        return try initChild(alloc, itt, opts);
    }
}

const NoSuchCollection = State.Error.NoSuchCollection;

pub fn run(self: *Self, state: *State, out_writer: anytype) !void {
    switch (self.selection) {
        .Child => |*c| try runChild(c, state, out_writer),
        .Collection => |s| {
            const ctype = s.container;
            const name = s.name;
            const index = state.getSelectedCollectionIndex(ctype, name) orelse
                return cli.SelectionError.InvalidSelection;

            var stdout = std.io.getStdOut().writer();
            try stdout.print(
                "Delete ENTIRE COLLECTION {s} '{s}'?\n",
                .{
                    switch (ctype) {
                        inline else => |i| @tagName(i),
                    },
                    name,
                },
            );
            if (try confirmPrompt(state, stdout)) {
                try state.removeCollection(ctype, index);
                try out_writer.print(
                    "{s} {s} deleted\n",
                    .{
                        switch (ctype) {
                            inline else => |i| @tagName(i),
                        },
                        name,
                    },
                );
            }
        },
    }
}

fn runChild(
    self: *RemoveChild,
    state: *State,
    _: anytype,
) !void {
    // we need to be interactive, so no buffering:
    var out_writer = std.io.getStdOut().writer();

    var item: State.MaybeItem = (try cli.find(state, self.where, self.selection.?)) orelse
        return NoSuchCollection;

    if (item.note != null and item.day == null) {
        // no day just note
        const note = item.note.?;
        try out_writer.print(
            "Delete '{s}' in directory '{s}'?\n",
            .{ note.getName(), note.Note.dir.description.name },
        );
        if (try confirmPrompt(state, out_writer)) {
            try note.remove();
            _ = try out_writer.writeAll("Note deleted\n");
        }
    } else if (item.day) |day| {
        if (self.time) |time| {
            // if a time is provided, then we delete the entry
            try removeItemInEntry(state, day, time, out_writer);
        } else {
            try out_writer.print(
                "Delete ENTIRE entry '{s}' in journal '{s}'?\n",
                .{ day.getName(), day.Day.journal.description.name },
            );
            if (try confirmPrompt(state, out_writer)) {
                try day.remove();
                _ = try out_writer.writeAll("Entry deleted\n");
            }
        }
    } else if (item.task) |task_item| {
        const task = task_item.Task;
        try out_writer.print(
            "Delete '{s}' in tasklist '{s}'?\n",
            .{ task_item.getName(), task.tasklist.info.name },
        );
        if (try confirmPrompt(state, out_writer)) {
            try task_item.remove();
            _ = try out_writer.writeAll("Task deleted\n");
        }
    } else unreachable;
}

fn removeItemInEntry(state: *State, day: State.Item, time: []const u8, out_writer: anytype) !void {
    var entries = try day.Day.read();

    // find the selected index
    const index = for (0..entries.len) |i| {
        const entry = entries[i];
        const created_time = try utils.formatTimeBuf(
            utils.dateFromMs(entry.created),
        );
        if (std.mem.eql(u8, &created_time, time)) {
            break i;
        }
    } else return cli.SelectionError.InvalidSelection;

    var entry = entries[index];

    // print the item
    try out_writer.print(
        "Selected item in {s}:\n\n {s} - {s}\n\n",
        .{ day.getName(), time, entry.item },
    );
    // delete message
    try out_writer.print(
        "Delete item in entry '{s}' in journal '{s}'?\n",
        .{ day.getName(), day.Day.journal.description.name },
    );

    if (try confirmPrompt(state, out_writer)) {
        try day.Day.removeEntryByIndex(index);
    }
}

const InputError = error{NoInput};

fn confirmPrompt(state: *State, out_writer: anytype) !bool {
    _ = try out_writer.writeAll("yes/[no]: ");

    var stdin = std.io.getStdIn().reader();
    const input = try stdin.readUntilDelimiterOrEofAlloc(
        state.allocator,
        '\n',
        1024,
    );
    defer if (input) |inp| state.allocator.free(inp);

    if (input) |inp| {
        _ = try out_writer.writeAll("\n");
        return std.mem.eql(u8, inp, "yes");
    } else return InputError.NoInput;
}
