const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const TaskPrinter = @import("../TaskPrinter.zig");

const Self = @This();

pub const help = "Modify attributes of entries, notes, chains, or tasks.";
pub const extended_help =
    \\Modify attributes of entries, notes, chains, or tasks.
    \\
    \\See `help task` for the date selection format specifiers.
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt set done "go to the shops"    # set a task as done
    \\  nkt set todo "pick up milk"       # set a completed task as todo
    \\  nkt set todo "email boss" \       # update due date of a task
    \\      --by tomorrow
    \\  nkt set done --chain paper        # set the chain link for 'paper' as done
    \\
;

const Importance = @import("../collections/Topology.zig").Task.Importance;

const parseDateTimeLike = cli.selections.parseDateTimeLike;
const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

const TaskAttributes = enum {
    Done,
    Todo,
    fn parseMode(string: []const u8) !TaskAttributes {
        if (std.mem.eql(u8, string, "todo")) return .Todo;
        if (std.mem.eql(u8, string, "done")) return .Done;
        return cli.CLIErrors.BadArgument;
    }
};
const ChainAttributes = enum {
    Alias,
    Done,
    fn parseMode(string: []const u8) !ChainAttributes {
        if (std.mem.eql(u8, string, "alias")) return .Alias;
        if (std.mem.eql(u8, string, "done")) return .Done;
        return cli.CLIErrors.BadArgument;
    }
};

const Mode = union(enum) {
    Task: struct {
        selection: cli.Selection = .{},
        attr: ?TaskAttributes = null,
        by: ?utils.Date = null,
        importance: ?Importance = null,

        pub fn parse(self: *@This(), itt: *cli.ArgIterator) !void {
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
                        1 => self.attr = try TaskAttributes.parseMode(arg.string),
                        2 => try self.selection.parseItem(arg),
                        else => return cli.CLIErrors.TooManyArguments,
                    }
                }
            }
        }
    },
    Chain: struct {
        name: []const u8 = "",
        alias: ?[]const u8 = null,
        attr: ?ChainAttributes = null,

        pub fn parse(self: *@This(), itt: *cli.ArgIterator) !void {
            while (try itt.next()) |arg| {
                if (arg.flag) {
                    if (arg.is('c', "chain")) {
                        const name_arg = (try itt.nextPositional()) orelse
                            return cli.CLIErrors.TooFewArguments;
                        self.name = name_arg.string;
                    } else if (arg.is(null, "alias")) {
                        if (self.alias != null)
                            return cli.CLIErrors.DuplicateFlag;
                        self.alias = (try itt.getValue()).string;
                    } else {
                        return cli.CLIErrors.UnknownFlag;
                    }
                } else {
                    if (self.attr == null) {
                        self.attr = try ChainAttributes.parseMode(arg.string);
                    } else {
                        switch (self.attr.?) {
                            .Alias => {
                                self.alias = arg.string;
                            },
                            else => return cli.CLIErrors.TooManyArguments,
                        }
                    }
                }
            }
        }
    },

    pub fn parse(mode: *Mode, itt: *cli.ArgIterator) !void {
        itt.counter = 0;
        switch (mode.*) {
            inline else => |*self| try self.parse(itt),
        }
    }

    pub fn validate(mode: *Mode) !void {
        switch (mode.*) {
            .Task => |*self| {
                self.attr = self.attr orelse
                    return cli.CLIErrors.TooFewArguments;

                if (!self.selection.validate(.Item)) {
                    return cli.CLIErrors.TooFewArguments;
                }
            },
            .Chain => |*self| {
                self.attr = self.attr orelse
                    return cli.CLIErrors.TooFewArguments;
                if (self.name.len == 0)
                    return cli.CLIErrors.TooFewArguments;
            },
        }
    }
};

fn determineMode(itt: *cli.ArgIterator) !Mode {
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('c', "chain")) {
                return .{ .Chain = .{} };
            }
        }
    }
    return .{ .Task = .{} };
}

mode: Mode,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var tempitt = itt.copy();
    var self: Self = .{ .mode = try determineMode(&tempitt) };

    try self.mode.parse(itt);
    try self.mode.validate();

    return self;
}

pub fn runAsTask(self: *Self, state: *State, out_writer: anytype) !void {
    var task_self = self.mode.Task;
    const selected: State.MaybeItem = (try task_self.selection.find(state)) orelse
        return cli.SelectionError.UnknownCollection;

    if (selected.task) |task| {
        switch (task_self.attr.?) {
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
                if (task_self.by) |by| {
                    task.Task.task.due = utils.msFromDate(by);
                }
                if (task_self.importance) |imp| {
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

pub fn runAsChain(self: *Self, state: *State, out_writer: anytype) !void {
    const chain_self = self.mode.Chain;

    var chain = (try state.getChainByName(chain_self.name)) orelse
        return cli.SelectionError.NoSuchCollection;

    switch (chain_self.attr.?) {
        .Alias => {
            const alias = chain_self.alias orelse
                return cli.SelectionError.InvalidSelection;
            chain.alias = alias;
            try out_writer.print("Modified alias of chain '{s}' as '{s}'\n", .{ chain.name, chain.alias.? });
            try state.writeChanges();
        },
        .Done => {
            if (doneToday(chain)) {
                try out_writer.print("Link for '{s}' already completed today.\n", .{chain.name});
            } else {
                _ = try utils.push(u64, state.topology.mem.allocator(), &chain.completed, utils.now());
                try out_writer.print("Link for '{s}' set as completed for today.\n", .{chain.name});
                try state.writeChanges();
            }
        },
    }
}

fn doneToday(chain: *const State.Chain) bool {
    if (chain.completed.len == 0) return false;

    const today = utils.dateFromMs(utils.now());
    const latest = chain.completed[chain.completed.len - 1];

    const delta = today.sub(utils.dateFromMs(latest));
    return (delta.years == 0 and delta.days == 0);
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    switch (self.mode) {
        .Task => {
            try self.runAsTask(state, out_writer);
        },
        .Chain => {
            try self.runAsChain(state, out_writer);
        },
    }
}
