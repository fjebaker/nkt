const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const TaskPrinter = @import("../TaskPrinter.zig");

const Self = @This();

pub const help = "Modify attributes of entries, notes, or tasks.";
pub const extended_help =
    \\Modify attributes of entries, notes, or tasks.
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt set done "go to the shops"    # set a task as done
    \\  nkt set todo "pick up milk"       # set a completed task as todo
    \\  nkt set todo "email boss" \       # update due date of a task
    \\      --by tomorrow
    \\
;

const Mode = enum { Done, Todo };

fn parseMode(string: []const u8) !Mode {
    if (std.mem.eql(u8, string, "todo")) return .Todo;
    if (std.mem.eql(u8, string, "done")) return .Done;
    return cli.CLIErrors.BadArgument;
}

mode: ?Mode = null,
where: ?cli.SelectedCollection = null,
selection: ?cli.Selection = null,

const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (try parseCollection(arg, itt, true)) |col| {
                if (self.where != null)
                    return cli.SelectionError.AmbiguousSelection;
                self.where = col;
            } else {
                return cli.CLIErrors.InvalidFlag;
            }
        } else {
            switch (arg.index.?) {
                1 => self.mode = try parseMode(arg.string),
                2 => self.selection = try cli.Selection.parse(arg.string),
                else => return cli.CLIErrors.TooManyArguments,
            }
        }
    }

    self.mode = self.mode orelse
        return cli.CLIErrors.TooFewArguments;
    self.selection = self.selection orelse
        return cli.CLIErrors.TooFewArguments;

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var selected: State.MaybeItem = (try cli.find(state, self.where, self.selection.?)) orelse
        return cli.SelectionError.UnknownCollection;
    if (selected.task) |task| {
        switch (self.mode.?) {
            .Done => {
                if (!task.Task.isDone()) {
                    task.Task.setDone();
                    _ = try out_writer.writeAll("Task marked as completed\n");
                } else {
                    _ = try out_writer.writeAll("Task is already marked as done\n");
                }
            },
            .Todo => {
                task.Task.setTodo();
                _ = try out_writer.writeAll("Task marked as todo\n");
            },
        }
    } else return cli.SelectionError.InvalidSelection;
}
