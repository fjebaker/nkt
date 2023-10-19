const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const notes = @import("../notes.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");
const DayEntry = @import("../DayEntry.zig");

const Self = @This();

pub const alias = [_][]const u8{"ls"};

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
        number: usize = 25,
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
        switch (config) {
            .days => {
                if (arg.flag) return cli.CLIErrors.UnknownFlag;
                return cli.CLIErrors.TooManyArguments;
            },
            .notes => |*opt| {
                if (arg.flag) {
                    if (arg.is('n', "number")) {
                        const value = try itt.getValue();
                        opt.number = try value.as(usize);
                    } else {
                        return cli.CLIErrors.UnknownFlag;
                    }
                } else {
                    switch (arg.index.?) {
                        1 => {
                            opt.day = try std.fmt.parseInt(usize, arg.string, 10);
                        },
                        else => return cli.CLIErrors.TooManyArguments,
                    }
                }
            },
        }
    }
    return .{ .config = config };
}

fn writeDiary(
    out_writer: anytype,
    entry: DayEntry,
    limit: usize,
) !void {
    try out_writer.print("Notes for {s}\n", .{try utils.formatDateBuf(entry.date)});

    const offset = @min(entry.notes.len, limit);
    const start = entry.notes.len - offset;

    for (entry.notes[start..]) |note| {
        const time_of_day = utils.adjustTimezone(utils.Date.initUnixMs(note.modified));
        try time_of_day.format("HH:mm:ss - ", .{}, out_writer);
        try out_writer.print("{s}\n", .{note.content});
    }
}

fn listNotes(
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
    config: Config,
) !void {
    const opts = config.notes;

    if (opts.day) |day| {
        var note = notes.Note{ .Day = .{ .i = day } };
        const date = try note.getDate(alloc, state);

        var diary = try DayEntry.openDate(alloc, date, state);
        defer diary.deinit();

        try writeDiary(out_writer, diary, opts.number);
    } else {
        var mem = std.heap.ArenaAllocator.init(alloc);
        defer mem.deinit();
        var temp_alloc = mem.allocator();

        var dl = try DayEntry.getDayList(temp_alloc, state);
        dl.sort();

        // calculate how many diary entries we need
        var list = std.ArrayList(DayEntry).init(temp_alloc);
        var note_count: usize = 0;
        for (0..dl.days.len) |i| {
            const date = dl.days[dl.days.len - i - 1];
            var diary = try DayEntry.openDate(temp_alloc, date, state);
            try list.append(diary);
            note_count += diary.notes.len;
            if (note_count >= opts.number) break;
        }

        std.mem.reverse(DayEntry, list.items);

        // print the first one truncated
        const difference = note_count -| opts.number;
        try writeDiary(out_writer, list.items[0], list.items[0].notes.len - difference);

        // print the rest
        if (list.items.len > 1) {
            for (list.items[1..]) |diary| {
                try writeDiary(out_writer, diary, note_count);
                note_count -|= diary.notes.len;
            }
        }
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
