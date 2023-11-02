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

const Importance = @import("../collections/Topology.zig").Task.Importance;

const parseDateTimeLike = cli.selections.parseDateTimeLike;
const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

const Mode = enum { Done, Todo };

fn parseMode(string: []const u8) !Mode {
    if (std.mem.eql(u8, string, "todo")) return .Todo;
    if (std.mem.eql(u8, string, "done")) return .Done;
    return cli.CLIErrors.BadArgument;
}

mode: ?Mode = null,
selection: cli.Selection = .{},
by: ?utils.Date = null,
importance: ?Importance = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (try self.selection.parseCollection(arg, itt)) {
                continue;
            } else if (arg.is('i', "importance")) {
                if (self.importance != null)
                    return cli.CLIErrors.DuplicateFlag;

                const val = (try itt.getValue()).string;
                self.importance = std.meta.stringToEnum(Importance, val) orelse
                    return cli.CLIErrors.BadArgument;
            } else if (try parseDateTimeLike(arg, itt, "by")) |date| {
                if (self.by != null) return cli.CLIErrors.DuplicateFlag;
                self.by = date;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            switch (arg.index.?) {
                1 => self.mode = try parseMode(arg.string),
                2 => try self.selection.parseItem(arg),
                else => return cli.CLIErrors.TooManyArguments,
            }
        }
    }

    self.mode = self.mode orelse
        return cli.CLIErrors.TooFewArguments;

    if (!self.selection.validate(.Item)) {
        return cli.CLIErrors.TooFewArguments;
    }

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var selected: State.MaybeItem = (try self.selection.find(state)) orelse
        return cli.SelectionError.UnknownCollection;

    if (selected.task) |task| {
        switch (self.mode.?) {
            .Done => {
                if (!task.Task.isDone()) {
                    task.Task.setDone();
                    try state.writeChanges();
                    try out_writer.print(
                        "Task '{s}' marked as completed\n",
                        .{task.getName()},
                    );
                } else {
                    _ = try out_writer.writeAll("Task is already marked as done\n");
                }
            },
            .Todo => {
                if (self.by) |by| {
                    task.Task.task.due = utils.msFromDate(by);
                }
                if (self.importance) |imp| {
                    task.Task.task.importance = imp;
                }
                if (task.Task.isDone()) {
                    task.Task.setTodo();
                }
                try state.writeChanges();
                try out_writer.print("Task '{s}' modified\n", .{task.getName()});
            },
        }
    } else return cli.SelectionError.InvalidSelection;
}
