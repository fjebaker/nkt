const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{"rm"};

pub const help = "Remove items from collections.";
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
++ cli.Selection.COLLECTION_FLAG_HELP ++
    \\     -f                    don't prompt for removal
    \\
;

selection: union(enum) {
    Child: cli.Selection,
    Collection: cli.selections.CollectionSelection,
} = .{ .Child = .{} },

fn initChild(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    var child = &self.selection.Child;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        // parse selection
        if (try child.parse(arg, itt)) continue;

        // handle other options
        if (arg.flag) {
            return cli.CLIErrors.UnknownFlag;
        } else {
            return cli.CLIErrors.TooManyArguments;
        }
    }

    if (!child.validate(.Item)) {
        return cli.CLIErrors.TooFewArguments;
    }
    return self;
}

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    const arg = (try itt.next()) orelse return cli.CLIErrors.TooFewArguments;
    if (arg.flag and arg.is(null, "collection")) {
        const selection = try cli.Selection.positionalNamedCollection(itt);
        return .{ .selection = .{ .Collection = selection.collection.? } };
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
                try state.writeChanges();
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
    selection: *cli.Selection,
    state: *State,
    _: anytype,
) !void {
    // we need to be interactive, so no buffering:
    var out_writer = std.io.getStdOut().writer();

    const item: State.MaybeItem = (try selection.find(state)) orelse
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
            try state.writeChanges();
            _ = try out_writer.writeAll("Note deleted\n");
        }
    } else if (item.day) |day| {
        if (day.Day.time != null) {
            // if a time is provided, then we delete the entry
            try removeItemInEntry(state, day, out_writer);
        } else {
            try out_writer.print(
                "Delete ENTIRETY OF '{s}' in journal '{s}'?\n",
                .{ day.getName(), day.Day.journal.description.name },
            );
            if (try confirmPrompt(state, out_writer)) {
                try day.remove();
                try state.writeChanges();
                _ = try out_writer.writeAll("Journal page deleted\n");
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
            try state.writeChanges();
            _ = try out_writer.writeAll("Task deleted\n");
        }
    } else unreachable;
}

fn removeItemInEntry(state: *State, day: State.Item, out_writer: anytype) !void {
    const index = try day.Day.indexAtTime();
    const entry = try day.Day.getEntry(index);

    // print the item
    try out_writer.print(
        "Selected item in {s}:\n\n {s} - {s}\n\n",
        .{ day.getName(), day.Day.time.?, entry.item },
    );
    // delete message
    try out_writer.print(
        "Delete item in entry '{s}' in journal '{s}'?\n",
        .{ day.getName(), day.Day.journal.description.name },
    );

    if (try confirmPrompt(state, out_writer)) {
        try day.Day.removeEntryByIndex(index);
        try state.writeChanges();
        _ = try out_writer.writeAll("Entry deleted\n");
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
