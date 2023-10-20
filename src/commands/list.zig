const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const notes = @import("../notes.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{"ls"};

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list
    \\     [-n/--limit int]      maximum number of entries to display
    \\     [--all]               list all entries (ignores `--limit`)
    \\     [--modified]          sort by last modified (default for notes)
    \\     [--created]           sort by date created (default for days)
    \\     [notes|days]          list either notes or days (default days)
    \\
;

const Options = enum { notes, days };

selection: Options,
ordering: State.Ordering,
number: usize,
all: bool,

pub fn init(itt: *cli.ArgIterator) !Self {
    var selection: ?Options = null;
    var number: usize = 25;
    var all: bool = false;
    var ordering: ?State.Ordering = null;

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                all = true;
            } else if (arg.is(null, "modified")) {
                ordering = .Modified;
            } else if (arg.is(null, "created")) {
                ordering = .Created;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (selection == null) {
                if (std.meta.stringToEnum(Options, arg.string)) |s| {
                    selection = s;
                }
            } else return cli.CLIErrors.TooManyArguments;
        }
    }

    const selected = selection orelse .days;
    return .{
        .selection = selected,
        .number = number,
        .all = all,
        .ordering = ordering orelse switch (selected) {
            .days => .Created,
            .notes => .Modified,
        },
    };
}

pub fn getDiaryDateList(
    state: *State,
) !utils.DateList {
    var diary_directory = try state.fs.iterableDiaryDirectory();
    defer diary_directory.close();

    var alloc = state.mem.allocator();

    var date_list = std.ArrayList(utils.Date).init(alloc);
    errdefer date_list.deinit();

    var iterator = diary_directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(
            u8,
            entry.name,
            notes.diary.DIARY_EXTRA_SUFFIX,
        )) |end| {
            const day = entry.name[0..end];
            const date = utils.toDate(day) catch continue;
            try date_list.append(date);
        }
    }

    return .{ .alloc = alloc, .items = try date_list.toOwnedSlice() };
}

fn listNotes(
    self: Self,
    state: *State,
    out_writer: anytype,
) !void {
    var notes_directory = try state.fs.iterableNotesDirectory();
    defer notes_directory.close();

    var note_list = try state.makeNoteList(self.ordering);
    defer note_list.deinit();

    switch (self.ordering) {
        .Modified => try out_writer.print("Notes ordered by last modified:\n", .{}),
        .Created => try out_writer.print("Notes ordered by date created:\n", .{}),
    }

    for (note_list.items) |note| {
        const date = switch (self.ordering) {
            .Modified => note.info.modifiedDate(),
            .Created => note.info.creationDate(),
        };
        const date_string = try utils.formatDateBuf(date);
        try out_writer.print("{s} - {s}\n", .{ date_string, note.info.name });
    }
}

fn listDays(
    self: Self,
    state: *State,
    out_writer: anytype,
) !void {
    var date_list = try getDiaryDateList(state);
    defer date_list.deinit();

    date_list.sort();

    const end = blk: {
        if (self.all) {
            try out_writer.print("All diary entries:\n", .{});
            break :blk date_list.items.len;
        } else {
            const end = @min(self.number, date_list.items.len);
            try out_writer.print("Last {d} diary entries:\n", .{end});
            break :blk end;
        }
    };

    for (1.., date_list.items[0..end]) |i, date| {
        const day = try utils.formatDateBuf(date);
        try out_writer.print("{d}: {s}\n", .{ end - i, day });
    }
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    switch (self.selection) {
        .notes => try self.listNotes(state, out_writer),
        .days => try self.listDays(state, out_writer),
    }
}
