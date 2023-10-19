const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const DayEntry = @import("../DayEntry.zig");
const State = @import("../State.zig");
const Editor = @import("../Editor.zig");

const Self = @This();

pub const help = "Edit a note with EDITOR.";
pub const extended_help =
    \\Edit a note with $EDITOR
    \\
    \\  nkt edit <name or day-like>
    \\
    \\Examples:
    \\=========
    \\
    \\  nkt edit 0         # edit day today (day 0)
    \\  nkt edit 2023-1-1  # edit day 2023-1-1
    \\  nkt edit lldb      # edit notes labeled `lldb`
    \\
;

pub const SelectionError = error{UnknownSelection};

fn isNumeric(c: u8) bool {
    return (c >= '0' and c <= '9');
}

fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c)) return false;
    }
    return true;
}

fn isDate(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c) and c != '-') return false;
    }
    return true;
}

const Selection = union(enum) {
    Day: usize,
    Date: utils.Date,
    File: []const u8,

    pub fn parse(string: []const u8) !Selection {
        if (allNumeric(string)) {
            const day = try std.fmt.parseInt(usize, string, 10);
            return .{ .Day = day };
        } else if (isDate(string)) {
            const date = try utils.toDate(string);
            return .{ .Date = date };
        } else {
            return .{ .File = string };
        }
    }
};

selection: Selection,

pub fn init(itt: *cli.ArgIterator) !Self {
    var string: ?[]const u8 = null;

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
        string = arg.string;
    }

    if (string) |s| {
        return .{ .selection = try Selection.parse(s) };
    } else {
        return cli.CLIErrors.TooFewArguments;
    }
}

fn editDate(
    temp_alloc: std.mem.Allocator,
    out_writer: anytype,
    date: utils.Date,
    state: *State,
) !void {
    const entry_path = try DayEntry.entryPathElseTemplate(temp_alloc, date, state);
    var editor = try Editor.init(temp_alloc);
    defer editor.deinit();

    const abs_path = try state.absPathify(temp_alloc, entry_path);
    try editor.editPath(abs_path);
    try out_writer.print("Written to '{s}'.\n", .{entry_path});
}

const FILE_EXTENSION = ".md";

pub fn run(
    self: *Self,
    alloc: std.mem.Allocator,
    out_writer: anytype,
    state: *State,
) !void {
    var mem = std.heap.ArenaAllocator.init(alloc);
    defer mem.deinit();

    var temp_alloc = mem.allocator();

    switch (self.selection) {
        .Date => {
            const date = self.selection.Date;
            try editDate(temp_alloc, out_writer, date, state);
        },
        .Day => {
            const choice = self.selection.Day;

            var dl = try DayEntry.getDayList(temp_alloc, state);
            dl.sort();

            const date = dl.days[dl.days.len - choice - 1];
            try editDate(temp_alloc, out_writer, date, state);
        },
        .File => {
            const filename = try std.mem.concat(temp_alloc, u8, &.{ self.selection.File, FILE_EXTENSION });
            const rel_path = try std.fs.path.join(
                temp_alloc,
                &.{ State.NOTES_DIRECTORY, filename },
            );
            const abs_path = try state.absPathify(temp_alloc, rel_path);

            var editor = try Editor.init(temp_alloc);
            defer editor.deinit();

            try editor.editPath(abs_path);

            try out_writer.print("Written to '{s}'.\n", .{rel_path});
        },
    }
}
