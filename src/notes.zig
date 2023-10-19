const std = @import("std");
const utils = @import("utils.zig");

const State = @import("State.zig");
const DayEntry = @import("DayEntry.zig");

pub const SelectionError = error{ UnknownSelection, NoDate };
pub const DEFAULT_FILE_EXTENSION = ".md";

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

pub const Note = union(enum) {
    Day: struct {
        i: usize,
        date: ?utils.Date = null,
    },
    Date: utils.Date,
    Name: []const u8,

    pub fn getDate(
        self: *Note,
        alloc: std.mem.Allocator,
        state: *State,
    ) !utils.Date {
        switch (self.*) {
            .Day => |*info| {
                if (info.date) |date| {
                    return date;
                } else {
                    var dl = try DayEntry.getDayList(alloc, state);
                    defer dl.deinit();
                    dl.sort();

                    const date = dl.days[dl.days.len - info.i - 1];
                    // save it for later
                    info.date = date;
                    return date;
                }
            },
            .Date => |date| return date,
            else => return SelectionError.NoDate,
        }
    }

    pub fn getRelPath(self: *Note, alloc: std.mem.Allocator, state: *State) ![]u8 {
        switch (self.*) {
            .Date, .Day => return DayEntry.entryPath(
                alloc,
                try self.getDate(alloc, state),
                state,
            ),
            .Name => |name| {
                const filename = try std.mem.concat(
                    alloc,
                    u8,
                    &.{ name, DEFAULT_FILE_EXTENSION },
                );
                defer alloc.free(filename);

                return std.fs.path.join(
                    alloc,
                    &.{ State.NOTES_DIRECTORY, filename },
                );
            },
        }
    }

    pub fn makeTemplate(
        self: *Note,
        alloc: std.mem.Allocator,
        rel_path: []const u8,
        state: *State,
    ) !void {
        var dir = try state.getDir();
        var fs = try dir.createFile(rel_path, .{});
        defer fs.close();

        var writer = fs.writer();

        switch (self.*) {
            .Day, .Date => {
                const date = try self.getDate(alloc, state);

                var day_of_week = try utils.dayOfWeek(alloc, date);
                defer alloc.free(day_of_week);

                var month_of_year = try utils.monthOfYear(alloc, date);
                defer alloc.free(month_of_year);

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

pub fn parse(string: []const u8) !Note {
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
