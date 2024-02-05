const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const help = "Select an item or collection";

selection: cli.Selection = .{},

pub fn init(
    _: std.mem.Allocator,
    itt: *cli.ArgIterator,
    opts: cli.Options,
) !Self {
    _ = opts;
    var self: Self = .{};

    itt.counter = 0;
    while (try itt.next()) |arg| {
        // parse selection
        if (try self.selection.parse(arg, itt)) continue;

        if (arg.flag) return cli.CLIErrors.UnknownFlag;
    }

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const selected: State.MaybeItem =
        (try self.selection.find(state)) orelse
        return State.Error.NoSuchCollection;

    if (selected.day) |item| {
        try printSelection(out_writer, item);
    }
    if (selected.note) |item| {
        try printSelection(out_writer, item);
    }
    if (selected.task) |item| {
        try printSelection(out_writer, item);
    }
}

fn printSelection(out_writer: anytype, item: State.Item) !void {
    switch (item) {
        .Note => |note| {
            try out_writer.print("> Note: {s}\n", .{note.note.name});
        },
        .Day => |day| {
            const index = day.indexAtTime() catch |err| {
                if (err == State.Item.DayError.NoTimeGiven) {
                    try out_writer.print("> Day: {s}\n", .{day.day.name});
                    return;
                } else return err;
            };

            try out_writer.print(
                "> Day: {s} index: {d} \n",
                .{ day.day.name, index },
            );
        },
        .Task => |task| {
            try out_writer.print("> Task: {s}\n", .{task.task.title});
        },
    }
}
