const std = @import("std");
pub const time = @import("time");
pub const DateError = error{DateStringTooShort};

pub const Time = time.datetime.Time;
pub const Date = time.datetime.Datetime;

pub fn dateFromMs(ms: u64) Date {
    return Date.fromTimestamp(@intCast(ms));
}

pub fn msFromDate(date: Date) u64 {
    return @intCast(date.toTimestamp());
}

pub fn ListMixin(comptime Self: type, comptime T: type) type {
    return struct {
        pub fn initSize(alloc: std.mem.Allocator, N: usize) !Self {
            var items = try alloc.alloc(T, N);
            return .{ .allocator = alloc, .items = items };
        }

        pub fn initOwned(alloc: std.mem.Allocator, items: []T) Self {
            if (@hasDecl(Self, "_init")) {
                @call(.auto, @field(Self, "_init"), .{ alloc, items });
            } else {
                return .{ .allocator = alloc, .items = items };
            }
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(Self, "_deinit")) {
                @call(.auto, @field(Self, "_deinit"), .{self});
            } else {
                self.allocator.free(self.items);
                self.* = undefined;
            }
        }

        pub fn reverse(self: *Self) void {
            std.mem.reverse(T, self.items);
        }
    };
}

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,

        pub usingnamespace ListMixin(Self, T);
    };
}

pub fn SortableList(comptime T: type, comptime lessThan: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: []T,

        pub usingnamespace ListMixin(Self, T);

        pub fn sort(self: *Self) void {
            std.sort.insertion(T, self.items, {}, lessThan);
        }
    };
}

fn dateSort(_: void, lhs: Date, rhs: Date) bool {
    return (lhs.toUnixMilli() < rhs.toUnixMilli());
}

pub const DateList = SortableList(Date, dateSort);

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

const TIMEZONE = time.timezones.GB;
const EQUINOX = d: {
    var date = Date.fromDate(2023, 10, 29) catch @compileError("Equinox: bad date");
    date.time.hour = 2;
    break :d date;
};

fn adjustTimezone(date: Date) Date {
    if (date.lt(EQUINOX)) return date.shiftHours(1);
    return date.shiftTimezone(&TIMEZONE);
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
    const month = try std.fmt.parseInt(u8, string[5..7], 10);
    const day = try std.fmt.parseInt(u8, string[8..10], 10);

    return newDate(year, month, day);
}

pub fn toTime(string: []const u8) !Time {
    if (string.len < 8) return DateError.DateStringTooShort;
    const hour = try std.fmt.parseInt(u8, string[0..2], 10);
    const minute = try std.fmt.parseInt(u8, string[3..5], 10);
    const seconds = try std.fmt.parseInt(u8, string[6..8], 10);
    return .{ .hour = hour, .minute = minute, .second = seconds };
}

pub fn areSameDay(d1: Date, d2: Date) bool {
    return d1.years == d2.years and d1.months == d2.months and d1.days == d2.days;
}

pub fn newDate(year: u16, month: u8, day: u8) !Date {
    return try Date.fromDate(year, month, day);
}

pub fn formatDateBuf(date: Date) ![10]u8 {
    const t_date = adjustTimezone(date);
    var buf: [10]u8 = undefined;
    var bufstream = std.io.fixedBufferStream(&buf);
    try bufstream.writer().print(
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ t_date.date.year, t_date.date.month, t_date.date.day },
    );
    return buf;
}

pub fn formatTimeBuf(date: Date) ![8]u8 {
    const t_date = adjustTimezone(date);
    var buf: [8]u8 = undefined;
    var bufstream = std.io.fixedBufferStream(&buf);
    try bufstream.writer().print(
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{ t_date.time.hour, t_date.time.minute, t_date.time.second },
    );
    return buf;
}

pub fn formatDateTimeBuf(date: Date) ![19]u8 {
    var buf: [19]u8 = undefined;

    const date_s = try formatDateBuf(date);
    const time_s = try formatTimeBuf(date);

    @memcpy(buf[0..10], &date_s);
    buf[10] = ' ';
    @memcpy(buf[11..], &time_s);

    return buf;
}

pub fn dayOfWeek(alloc: std.mem.Allocator, date: Date) ![]const u8 {
    const t_date = adjustTimezone(date);
    return alloc.dupe(u8, t_date.date.weekdayName());
}

pub fn monthOfYear(alloc: std.mem.Allocator, date: Date) ![]const u8 {
    const t_date = adjustTimezone(date);
    return alloc.dupe(u8, t_date.date.monthName());
}

pub fn push(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: *[]T,
    new: T,
) !*T {
    var new_list = try allocator.alloc(T, list.len + 1);
    for (new_list[0..list.len], list.*) |*i, j| i.* = j;
    new_list[list.len] = new;
    allocator.free(list.*);
    list.* = new_list;
    return &list.*[list.len - 1];
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
    var date = t: {
        var d = try Date.fromDate(2023, 10, 10);
        d.time.hour = 23;
        d.time.minute = 13;
        d.time.second = 0;
        break :t d;
    };
    const new = adjustTimezone(date);
    try std.testing.expectEqual(new.time.hour, 0);
    try std.testing.expectEqual(new.date.day, 11);
}

pub fn moveToEnd(comptime T: type, items: []T, index: usize) void {
    const swap = std.mem.swap;
    for (items[index..], index + 1..) |*ptr, i| {
        // check we're not going past the end
        if (i == items.len) break;
        const next_ptr = &items[i];
        swap(T, ptr, next_ptr);
    }
}

const Tag = @import("collections.zig").Tag;
pub fn emptyTagList(allocator: std.mem.Allocator) ![]Tag {
    return try allocator.alloc(Tag, 0);
}

pub fn inferCollectionName(s: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, s, '/') orelse return null;
    if (std.mem.eql(u8, s[0..3], "dir")) return s[4..end];
    unreachable; // todo
}

pub const UriSlice = struct {
    start: usize,
    end: usize,
    uri: std.Uri,
};

pub fn findUriFromColon(text: []const u8, index_of_colon: usize) ?UriSlice {
    const start = index_of_colon;
    // too few characters remaining
    if (!(text.len >= start + 3))
        return null;

    const lookahead = text[start + 1 .. start + 3];

    if (!std.mem.eql(u8, lookahead, "//"))
        return null;
    // get the word boundaries
    const begin = b: {
        var i: usize = start - 1;
        while (i >= 0) {
            const c = text[i];
            if (std.ascii.isWhitespace(c) or c == '(') break :b i + 1;
            if (i == 0) break :b 0;
            i -= 1;
        }
        unreachable;
    };
    const end = std.mem.indexOfAnyPos(u8, text, start + 2, " )\n\t\r") orelse
        text.len;
    const slice = text[begin..end];
    const uri = std.Uri.parse(slice) catch {
        return null;
    };
    return .{
        .start = begin,
        .end = end,
        .uri = uri,
    };
}

pub fn Iterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }
        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const item = self.items[self.index];
            self.index += 1;
            return item;
        }
    };
}

pub fn ReverseIterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }
        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const i = self.items.len - self.index - 1;
            const item = self.items[i];
            self.index += 1;
            return item;
        }
    };
}
