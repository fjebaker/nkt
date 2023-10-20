const std = @import("std");
const utils = @import("utils.zig");
const cli = @import("cli.zig");

const list = @import("./commands/list.zig");

const State = @import("State.zig");

pub const diary = @import("diary.zig");

pub const SelectionError = error{ UnknownSelection, NoDate };

pub const DEFAULT_FILE_EXTENSION = ".md";

pub fn today() AnyNote {
    return .{ .Day = .{ .i = 0 } };
}

pub const AnyNote = union(enum) {
    Day: struct {
        i: usize,
        date: ?utils.Date = null,
    },
    Date: utils.Date,
    Name: []const u8,

    pub fn getDate(
        self: *AnyNote,
        state: *State,
    ) !utils.Date {
        switch (self.*) {
            .Day => |*info| {
                if (info.date) |date| {
                    return date;
                } else {
                    var date_list = try list.getDiaryDateList(state);
                    defer date_list.deinit();

                    date_list.sort();
                    const date =
                        date_list.items[date_list.items.len - info.i - 1];

                    info.date = date;
                    return date;
                }
            },
            .Date => |date| return date,
            else => return SelectionError.NoDate,
        }
    }

    /// Get the relative filepath of the note from state.
    /// State owns the memory.
    pub fn getRelPath(self: *AnyNote, state: *State) ![]const u8 {
        var alloc = state.mem.allocator();
        switch (self.*) {
            .Date, .Day => return diary.diaryPath(state, try self.getDate(state)),
            .Name => |name| {
                const filename = try std.mem.concat(
                    alloc,
                    u8,
                    &.{ name, DEFAULT_FILE_EXTENSION },
                );
                return std.fs.path.join(
                    alloc,
                    &.{ State.FileSystem.NOTES_DIRECTORY, filename },
                );
            },
        }
    }

    /// Populate the rel_path file with a template of the given note type.
    /// Asserts file does not already exist.
    pub fn makeTemplate(
        self: *AnyNote,
        state: *State,
        rel_path: []const u8,
    ) !void {
        var fs = try state.fs.dir.createFile(rel_path, .{});
        defer fs.close();

        var writer = fs.writer();
        var alloc = state.mem.allocator();

        switch (self.*) {
            .Day, .Date => {
                const date = try self.getDate(state);

                const day_of_week = try utils.dayOfWeek(alloc, date);
                const month_of_year = try utils.monthOfYear(alloc, date);

                try writer.print(
                    "# {s} - {s} of {s}\n\n",
                    .{
                        try utils.formatDateBuf(date),
                        day_of_week,
                        month_of_year,
                    },
                );
            },
            .Name => {},
        }
    }
};

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

pub fn parse(string: []const u8) !AnyNote {
    if (std.mem.eql(u8, string, "today") or std.mem.eql(u8, string, "t")) {
        const date = utils.Date.now();
        return .{ .Date = date };
    } else if (allNumeric(string)) {
        const day = try std.fmt.parseInt(usize, string, 10);
        return .{ .Day = .{ .i = day } };
    } else if (isDate(string)) {
        const date = try utils.toDate(string);
        return .{ .Date = date };
    } else {
        return .{ .Name = string };
    }
}

pub fn optionalParse(
    itt: *cli.ArgIterator,
) !?AnyNote {
    const arg = (try itt.next()) orelse return null;
    if (arg.flag) {
        itt.rewind();
        return null;
    }
    return try parse(arg.string);
}
