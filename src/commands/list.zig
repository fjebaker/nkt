const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list
    \\     [notes] [day]         list the diary notes made today or on
    \\                           [day] if specified.
    \\     [days]                enumerate the last diary entries.
    \\Without any arguments, default to `notes`.
    \\
;

const Options = enum { notes, days };

const Config = union(Options) {
    notes: struct {
        day: ?usize = null,
    },
    days: void,

    pub fn init(what: Options) Config {
        return switch (what) {
            .days => .{ .days = {} },
            inline else => |tag| @unionInit(Config, @tagName(tag), .{}),
        };
    }
};

config: Config,

pub fn init(itt: *cli.ArgIterator) !Self {
    var what: Options = .notes;

    const sub_command = try itt.next();
    if (sub_command) |sc| {
        if (std.meta.stringToEnum(Options, sc.string)) |w| {
            what = w;
        } else {
            // hacky positional rewind
            itt.args.index -= 1;
        }
    }

    var config = Config.init(what);

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        switch (config) {
            .days => {
                return cli.CLIErrors.TooManyArguments;
            },
            .notes => |*opt| {
                switch (arg.index.?) {
                    1 => {
                        opt.day = try std.fmt.parseInt(usize, arg.string, 10);
                    },
                    else => return cli.CLIErrors.TooManyArguments,
                }
            },
        }
    }
    return .{ .config = config };
}

fn listNotes(
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
    config: Config,
) !void {
    const opts = config.notes;
    const choice = opts.day orelse 0;

    var dl = try DayEntry.getDayList(alloc, state);
    defer dl.deinit();
    dl.sort();

    const selection = dl.days[dl.days.len - choice - 1];

    var day = try DayEntry.openDate(alloc, selection, state);
    defer day.deinit();

    try out_writer.print("Notes for {s}\n", .{try utils.formatDateBuf(day.date)});

    for (day.notes) |note| {
        const time_of_day = utils.adjustTimezone(utils.Date.initUnixMs(note.modified));
        try time_of_day.format("HH:mm:ss - ", .{}, out_writer);
        try out_writer.print("{s}\n", .{note.content});
    }
}

fn listDays(alloc: std.mem.Allocator, out_writer: anytype, state: *State) !void {
    var daylist = try DayEntry.getDayList(alloc, state);
    defer daylist.deinit();

    daylist.sort();

    for (1.., daylist.days) |i, date| {
        var day = try utils.formatDate(alloc, date);
        defer alloc.free(day);
        try out_writer.print("{d}: {s}\n", .{ daylist.days.len - i, day });
    }
}

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    switch (self.config) {
        .notes => try listNotes(alloc, out_writer, state, self.config),
        .days => try listDays(alloc, out_writer, state),
    }
}
