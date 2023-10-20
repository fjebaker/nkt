const std = @import("std");
const time = @import("time");

pub const DateError = error{DateStringTooShort};

pub const Date = time.DateTime;

pub fn List(comptime T: type, comptime lessThan: anytype) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        items: []T,

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.items);
            self.* = undefined;
        }

        pub fn sort(self: *Self) void {
            std.sort.insertion(T, self.items, {}, lessThan);
        }

        pub fn reverse(self: *Self) void {
            std.mem.reverse(T, self.items);
        }
    };
}

fn dateSort(_: void, lhs: Date, rhs: Date) bool {
    return (lhs.toUnixMilli() < rhs.toUnixMilli());
}

pub const DateList = List(Date, dateSort);

pub fn isAlias(
    comptime field: std.builtin.Type.UnionField,
    name: []const u8,
) bool {
    if (@hasDecl(field.type, "alias")) {
        inline for (@field(field.type, "alias")) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
        }
    }
    return false;
}

pub fn adjustTimezone(date: Date) Date {
    var modified = date.addHours(1);
    if (modified.hours >= 24) {
        const rem = modified.hours % 24;
        const days = modified.hours / 24;
        modified = date.addDays(days);
        modified.hours = rem;
    }
    return modified;
}

pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).ErrorSet.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(anyerror, e.name);
    }
    return null;
}

pub fn now() u64 {
    return @intCast(std.time.milliTimestamp());
}

pub fn toDate(string: []const u8) !Date {
    if (string.len < 10) return DateError.DateStringTooShort;
    const year = try std.fmt.parseInt(u16, string[0..4], 10);
    // months and day start at zero
    const month = try std.fmt.parseInt(u16, string[5..7], 10) - 1;
    const day = try std.fmt.parseInt(u16, string[8..10], 10) - 1;

    return Date.init(year, month, day, 0, 0, 0);
}

pub fn formatDate(alloc: std.mem.Allocator, date: Date) ![]const u8 {
    const t_date = adjustTimezone(date);
    return t_date.formatAlloc(alloc, "YYYY-MM-DD");
}

pub fn formatDateBuf(date: Date) ![10]u8 {
    const t_date = adjustTimezone(date);
    var buf: [10]u8 = undefined;
    var bufstream = std.io.fixedBufferStream(&buf);
    var writer = bufstream.writer();
    try t_date.format("YYYY-MM-DD", .{}, writer);
    return buf;
}

pub fn dayOfWeek(alloc: std.mem.Allocator, date: Date) ![]const u8 {
    const t_date = adjustTimezone(date);
    return t_date.formatAlloc(alloc, "dddd");
}

pub fn monthOfYear(alloc: std.mem.Allocator, date: Date) ![]const u8 {
    const t_date = adjustTimezone(date);
    return t_date.formatAlloc(alloc, "MMMM");
}

fn testToDateAndBack(s: []const u8) !void {
    const date = try toDate(s);
    const back = try formatDateBuf(date);
    try std.testing.expectEqualSlices(u8, s, back[0..10]);
}

test "to date" {
    try testToDateAndBack("2023-01-10");
    try testToDateAndBack("2010-02-19");
    try testToDateAndBack("2017-11-19");
}

test "time shift" {
    var date = Date.init(2023, 10, 10, 23, 13, 0);
    const new = adjustTimezone(date);
    try std.testing.expectEqual(new.hours, 0);
    try std.testing.expectEqual(new.days, 11);
}
