const std = @import("std");
const time = @import("time");
const chrono = @import("chrono");
const utils = @import("../utils.zig");

pub const Timestamp = time.datetime.Time;
pub const Date = time.datetime.Datetime;
pub const Weekday = time.datetime.Weekday;

pub const Error = error{DateTooShort};

// singleton for the current time zone
var global_time_zone: ?struct {
    tz: TimeZone,
    mem: std.heap.ArenaAllocator,
} = null;

fn getTimeZoneAllocator() std.mem.Allocator {
    if (global_time_zone) |*gtz| {
        return gtz.mem.allocator();
    } else {
        @panic("No timezone allocator");
    }
}

fn getLocalTimeZone() TimeZone {
    if (global_time_zone) |gtz| {
        return gtz.tz;
    } else {
        @panic("No local timezone");
    }
}

/// Deinitialize the timezone memory
pub fn deinitTimeZone() void {
    if (global_time_zone) |gtz| {
        gtz.mem.deinit();
    }
    global_time_zone = null;
}

/// Initialize the global time zone as UTC (mainly for tests)
pub fn initTimeZoneUTC(allocator: std.mem.Allocator) !TimeZone {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();
    const tz = time.timezones.UTC;
    global_time_zone = .{ .tz = .{ .tz = tz }, .mem = mem };
    return getLocalTimeZone();
}

/// Initialize the global time zone
pub fn initTimeZone(allocator: std.mem.Allocator) !TimeZone {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();

    switch (@import("builtin").os.tag) {
        .linux, .macos => {}, // ok
        else => @compileError("Timezone not inferrable for this OS in current version"),
    }

    var tzdb = try chrono.tz.DataBase.init(mem.allocator());
    defer tzdb.deinit();

    const timezone = try tzdb.getLocalTimeZone();

    const timestamp_utc = std.time.timestamp();
    const local_offset = timezone.offsetAtTimestamp(timestamp_utc) orelse 0;
    const designation = timezone.designationAtTimestamp(timestamp_utc) orelse "NA";

    const tz = time.datetime.Timezone.create(
        try mem.allocator().dupe(u8, designation),
        @intCast(@divFloor(local_offset, 60)), // convert to minutes
    );

    global_time_zone = .{ .tz = .{ .tz = tz }, .mem = mem };
    return getLocalTimeZone();
}

/// The type representing times in the topology: an integer counting
/// miliseconds since epoch in UTC
pub const Time = struct {
    /// Time stamp always UTC since epoch
    time: u64,
    /// Timezone for this time stamp
    timezone: ?TimeZone = null,

    /// Get the time now as `Time`
    pub fn now() Time {
        return .{
            .time = @intCast(std.time.milliTimestamp()),
            .timezone = getLocalTimeZone(),
        };
    }

    /// Get a `Time` from a `Date`
    pub fn fromDate(date: Date) Time {
        const utc_date = date.shiftTimezone(&time.timezones.UTC);
        return .{
            .time = @intCast(utc_date.toTimestamp()),
            .timezone = TimeZone.fromDate(date),
        };
    }

    /// Turn a `Time` into a `Date`, shifting the timezone if appropriate
    pub fn toDate(t: *const Time) Date {
        const date = Date.fromTimestamp(@intCast(t.time));
        return date.shiftTimezone(&t.getTimeZone().tz);
    }

    /// Get the `TimeZone` of the `Time`
    pub fn getTimeZone(t: Time) TimeZone {
        return t.timezone orelse getLocalTimeZone();
    }

    // Greater than comparison `t1 > t2`
    pub fn gt(s: Time, o: Time) bool {
        return s.time > o.time;
    }

    // Less than comparison `t1 < t2`
    pub fn lt(s: Time, o: Time) bool {
        return s.time < o.time;
    }

    /// Check whether two times are equal or not
    pub fn eql(s: Time, o: Time) bool {
        return s.time == o.time;
    }

    /// Turn a `YYYY-MM-DDTHH:MM:SS+HH:MM` into a `Time`
    pub fn fromString(s: []const u8) !Time {
        var date = try stringToDate(s[0..10]);
        const time_of_day = try toTimestamp(s[11..19]);
        date.time = time_of_day;

        const time_zone_shift = try std.fmt.parseInt(
            i16,
            s[20..22],
            10,
        );
        const minute_shift = try std.fmt.parseInt(
            i16,
            s[23..],
            10,
        );

        const hour_shift = if (s[19] == '+')
            time_zone_shift
        else
            -time_zone_shift;

        const tz = TimeZone.create(
            "---",
            (hour_shift * 60) + minute_shift,
        );

        date.zone = &tz.tz;
        return Time.fromDate(date);
    }

    // TODO: make this a `std.fmt` format function

    /// Format as `YYYY-MM-DD`
    pub fn formatDate(t: Time, allocator: std.mem.Allocator) ![]const u8 {
        // TODO: rename this function `formatDateAlloc`
        const buf = try formatDateBuf(t.toDate());
        return try allocator.dupe(u8, &buf);
    }

    /// Format as `HH:MM:SS`
    pub fn formatTime(t: Time) ![8]u8 {
        return try formatTimeBuf(t.toDate());
    }

    /// Format as `YYYY-MM-DD HH:MM:SS`
    pub fn formatDateTime(t: Time) ![19]u8 {
        return try formatDateTimeBuf(t.toDate());
    }

    pub fn jsonStringify(t: Time, writer: anytype) !void {
        const tz = t.getTimeZone();
        tz.printTimeImpl(writer, t, true) catch {
            return error.OutOfMemory;
        };
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Time {
        _ = allocator;
        _ = options;
        const token = try source.next();

        switch (token) {
            .number => |number| {
                const val = std.fmt.parseInt(u64, number, 10) catch {
                    return error.InvalidNumber;
                };
                return timeFromMilisUK(val);
            },
            .string => |string| {
                return Time.fromString(string) catch error.InvalidNumber;
            },
            else => return error.InvalidNumber,
        }
    }

    /// `Time` from milis, assuming the time stamp is from the UK.
    /// This is very specific to my needs.
    pub fn timeFromMilisUK(val: u64) Time {
        const tz = if (val < 1698544800000) // 29 October 2024
            TimeZone.create("BST", 60)
        else if (val < 1711846800000) // 31 March 2024
            TimeZone.create("UTC", 0)
        else
            getLocalTimeZone();

        return .{
            .time = val,
            .timezone = tz,
        };
    }
};

pub const TimeZone = struct {
    tz: time.datetime.Timezone,

    pub fn fromDate(date: Date) TimeZone {
        return .{
            .tz = date.zone.*,
        };
    }

    /// Format a UTC date with the given timezone for saving to disk or
    /// displaying Caller owns memory
    pub fn formatTime(self: TimeZone, allocator: std.mem.Allocator, t: Time) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();
        try self.printTime(list.writer(), t);
        return list.toOwnedSlice();
    }

    /// Format a UTC date with the given timezone for saving to disk or
    /// displaying Caller owns memory
    pub fn printTime(self: TimeZone, writer: anytype, t: Time) !void {
        try self.printTimeImpl(writer, t, false);
    }

    fn printTimeImpl(self: TimeZone, writer: anytype, t: Time, comptime quoted: bool) !void {
        var date = t.toDate();
        date.zone = &self.tz;

        var buf: [128]u8 = undefined;
        const fmt = try date.formatISO8601Buf(&buf, false);

        if (quoted) {
            try writer.print("\"{s}\"", .{fmt});
        } else {
            try writer.print("{s}", .{fmt});
        }
    }

    /// Initialize a UTC timezone
    pub fn initUTC() !TimeZone {
        return .{ .tz = time.timezones.UTC };
    }

    /// Create a timezone with a designation and minute offset
    pub fn create(name: []const u8, offset_minutes: i16) TimeZone {
        const dupe_name = getTimeZoneAllocator().dupe(u8, name) catch
            @panic("Out of memory");
        const tz = time.datetime.Timezone.create(
            dupe_name,
            offset_minutes,
        );
        return .{
            .tz = tz,
        };
    }

    /// Get the local time now
    pub fn localTimeNow(self: TimeZone) Date {
        return self.makeLocal(Time.now().toDate());
    }
};

/// Turn a `DateString` into a `Date`
pub fn dateFromDateString(s: []const u8) !Date {
    return Time.fromString(s).toDate();
}

test "date string conversion" {
    var tz = try initTimeZoneUTC(std.testing.allocator);
    defer deinitTimeZone();
    const t = Time.now();

    const timeDate = try tz.formatTime(std.testing.allocator, t);
    defer std.testing.allocator.free(timeDate);

    // TODO: actually add some good tests here
    _ = try Time.fromString(timeDate);
}

/// Counts the occurances of `spacer` in `string` and ensures all non spacer
/// characters are digits, else returns null. Returns `spacer` count.
fn formattedDigitFilter(comptime spacer: u8, string: []const u8) ?usize {
    var spacer_count: usize = 0;
    for (string) |c| {
        if (!std.ascii.isDigit(c) and c != spacer) return null;
        if (c == spacer) spacer_count += 1;
    }
    return spacer_count;
}

/// Is the string a YYYY-MM-DD format?
pub fn isDate(string: []const u8) bool {
    if (formattedDigitFilter('-', string)) |count| {
        if (count == 2) return true;
    }
    return false;
}

/// Is the string a HH:MM:SS format?
pub fn isTime(string: []const u8) bool {
    if (formattedDigitFilter(':', string)) |count| {
        if (count == 2) return true;
    }
    return false;
}

/// Make a new date with the given year month and day in UTC
pub fn newDate(year: u16, month: u8, day: u8) !Date {
    return try Date.fromDate(year, month, day);
}

/// Convert a `YYYY-MM-DD` string to a `Date`
pub fn stringToDate(string: []const u8) !Date {
    if (string.len < 10) return Error.DateTooShort;
    const year = try std.fmt.parseInt(u16, string[0..4], 10);
    // months and day start at zero
    const month = try std.fmt.parseInt(u8, string[5..7], 10);
    const day = try std.fmt.parseInt(u8, string[8..10], 10);
    return newDate(year, month, day);
}

/// Format a `Date` as YYYY-MM-DD
pub fn formatDateBuf(date: Date) ![10]u8 {
    var buf: [10]u8 = undefined;
    var bufstream = std.io.fixedBufferStream(&buf);
    try bufstream.writer().print(
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ date.date.year, date.date.month, date.date.day },
    );
    return buf;
}

/// Format a `Date` as HH:MM:SS
pub fn formatTimeBuf(date: Date) ![8]u8 {
    var buf: [8]u8 = undefined;
    var bufstream = std.io.fixedBufferStream(&buf);
    try bufstream.writer().print(
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{ date.time.hour, date.time.minute, date.time.second },
    );
    return buf;
}

/// Format a `Date` as YYYY-MM-DD HH:MM:SS
pub fn formatDateTimeBuf(date: Date) ![19]u8 {
    var buf: [19]u8 = undefined;

    const date_s = try formatDateBuf(date);
    const time_s = try formatTimeBuf(date);

    @memcpy(buf[0..10], &date_s);
    buf[10] = ' ';
    @memcpy(buf[11..], &time_s);

    return buf;
}

/// Get the day of the week as a string. Caller owns memory.
pub fn dayOfWeek(date: Date) ![]const u8 {
    return date.date.weekdayName();
}

/// Get the month of the year as a string. Caller owns memory.
pub fn monthOfYear(date: Date) ![]const u8 {
    return date.date.monthName();
}

/// Shift back a `Time` to a `Date`.
pub fn shiftBack(t: Time, index: usize) Date {
    return t.toDate().shiftDays(
        -@as(i32, @intCast(index)),
    );
}

/// Convert a string to an HH MM SS timestamp
pub fn toTimestamp(string: []const u8) !Timestamp {
    if (string.len < 8) return Error.DateTooShort;
    const hour = try std.fmt.parseInt(u8, string[0..2], 10);
    const minute = try std.fmt.parseInt(u8, string[3..5], 10);
    const seconds = try std.fmt.parseInt(u8, string[6..8], 10);
    return .{ .hour = hour, .minute = minute, .second = seconds };
}

const Duration = enum {
    hours,
    days,
    weeks,
    months,
    pub fn toDelta(d: Duration, num: u16) Date.Delta {
        return switch (d) {
            .hours => .{
                .seconds = @as(i64, @intCast(num)) * std.time.s_per_hour,
            },
            .days => .{ .days = @intCast(num) },
            .weeks => .{ .days = @as(i32, @intCast(num)) * 7 },
            .months => .{ .days = @as(i32, @intCast(num)) * 30 },
        };
    }
};

fn stringToDuration(s: []const u8) ?Duration {
    if (utils.stringEqualOrPlural(s, "hour", null)) {
        return .hours;
    }
    if (utils.stringEqualOrPlural(s, "day", null)) {
        return .days;
    }
    if (utils.stringEqualOrPlural(s, "week", null)) {
        return .weeks;
    }
    if (utils.stringEqualOrPlural(s, "month", null)) {
        return .months;
    }
    return null;
}

/// Struct representing a colloquial manner for describing time offsets. Used
/// to parse strings such as `today` or `tomorrow evening`.
pub const Colloquial = struct {
    const Tokenizer = std.mem.TokenIterator(u8, .any);
    const DEFAULT_TIME = toTimestamp("13:00:00") catch
        @compileError("Could not default parse date");

    tkn: Tokenizer,
    now: Date,

    fn _eq(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    fn setTime(_: *const Colloquial, date: Date, t: Timestamp) Date {
        var day = date;
        day.time.hour = t.hour;
        day.time.minute = t.minute;
        day.time.second = t.second;
        return day;
    }

    fn nextOrNull(c: *Colloquial) ?[]const u8 {
        return c.tkn.next();
    }

    fn next(c: *Colloquial) ![]const u8 {
        return c.tkn.next() orelse
            error.BadArgument;
    }

    fn peek(c: *Colloquial) ?[]const u8 {
        return c.tkn.peek();
    }

    fn optionalTime(c: *Colloquial) !Timestamp {
        const time_like = c.nextOrNull() orelse
            return DEFAULT_TIME;
        return try timeOfDay(time_like);
    }

    pub fn parse(c: *Colloquial) !Date {
        var arg = try c.next();

        if (_eq(arg, "soon")) {
            var prng = std.Random.DefaultPrng.init(Time.now().time);
            const days_different = prng.random().intRangeAtMost(
                i32,
                3,
                5,
            );
            return c.setTime(
                c.now.shiftDays(days_different),
                DEFAULT_TIME,
            );
        } else if (_eq(arg, "next")) {
            // only those that semantically follow 'next'
            arg = try c.next();
            if (_eq(arg, "week")) {
                const monday = c.parseWeekday("monday").?;
                return c.setTime(
                    monday,
                    try c.optionalTime(),
                );
            }
        } else if (_eq(arg, "today")) {
            // predicated
            return c.setTime(c.now, try c.optionalTime());
        } else if (_eq(arg, "tomorrow")) {
            return c.setTime(
                c.now.shiftDays(1),
                try c.optionalTime(),
            );
        } else if (isDate(arg)) {
            const date = try stringToDate(arg);
            return c.setTime(date, try c.optionalTime());
        }

        // test for offset, e.g. 10 days, 2 weeks
        if (utils.allNumeric(arg)) {
            if (c.peek()) |n| {
                if (stringToDuration(n)) |dur| {
                    _ = try c.next();
                    const num = try std.fmt.parseInt(
                        u16,
                        arg,
                        10,
                    );
                    const delta = dur.toDelta(num);
                    return c.setTime(c.now.shift(delta), DEFAULT_TIME);
                }
            }
        }

        // mutual
        if (c.parseWeekday(arg)) |date| {
            std.log.default.debug("Colloquial offset to '{s}'", .{arg});
            return c.setTime(date, try c.optionalTime());
        }

        return error.BadArgument;
    }

    fn parseNextTime(c: *Colloquial) !Date {
        if (c.parseWeekday(try c.next())) |date| {
            _ = date;
        }
    }

    fn asWeekday(arg: []const u8) ?Weekday {
        inline for (1..8) |i| {
            const weekday: Weekday = @enumFromInt(i);
            var name = @tagName(weekday);
            if (_eq(name[1..], arg[1..])) {
                if (name[0] == std.ascii.toUpper(arg[0])) {
                    return weekday;
                }
            }
        }
        return null;
    }

    fn parseWeekday(c: *const Colloquial, arg: []const u8) ?Date {
        const today = c.now.date.dayOfWeek();
        const shift = daysDifferent(today, arg) orelse return null;
        return c.now.shiftDays(shift);
    }

    fn daysDifferent(today_wd: Weekday, arg: []const u8) ?i32 {
        const choice = asWeekday(arg) orelse return null;
        const today: i32 = @intCast(@intFromEnum(today_wd));
        var selected: i32 = @intCast(@intFromEnum(choice));

        if (selected <= today) {
            selected += 7;
        }
        return (selected - today);
    }

    fn _compTime(comptime s: []const u8) Timestamp {
        return toTimestamp(s) catch
            @compileError("Could not parse time: " ++ s);
    }

    const TIME_OF_DAY = std.StaticStringMap(Timestamp).initComptime(.{
        .{ "morning", _compTime("08:00:00") },
        .{ "lunch", _compTime("13:00:00") },
        .{ "eod", _compTime("17:00:00") },
        .{ "end-of-day", _compTime("17:00:00") },
        .{ "evening", _compTime("19:00:00") },
        .{ "night", _compTime("23:00:00") },
    });

    fn timeOfDay(s: []const u8) !Timestamp {
        if (isTime(s)) {
            return try toTimestamp(s);
        }

        if (TIME_OF_DAY.get(s)) |t| return t;
        return Timestamp{ .hour = 13, .minute = 0, .second = 0 };
    }
};

fn testWeekday(now: Weekday, arg: []const u8, diff: i32) !void {
    const delta = Colloquial.daysDifferent(now, arg);
    try std.testing.expectEqual(delta, diff);
}

fn parseTimelikeDate(relative: Date, timelike: []const u8) !Date {
    const itt = std.mem.tokenizeAny(u8, timelike, " ");
    var col = Colloquial{ .tkn = itt, .now = relative };
    return try col.parse();
}

/// Parse a time-like string into a time. See also `Colloquial`. Any relative time-like will be relative to the time in `relative`.
pub fn parseTimelike(relative: Time, timelike: []const u8) !Time {
    const itt = std.mem.tokenizeAny(u8, timelike, " ");

    var col = Colloquial{ .tkn = itt, .now = relative.toDate() };
    const parsed = try col.parse();

    var t = Time.fromDate(parsed);
    t.timezone = relative.timezone;
    std.log.default.debug(
        "parsed time like as {d} + {d}",
        .{ t.time, t.timezone.?.tz.offset },
    );
    return t;
}

test "time selection parsing" {
    try testWeekday(.Monday, "tuesday", 1);
    try testWeekday(.Thursday, "tuesday", 5);
    try testWeekday(.Sunday, "sunday", 7);
    try testWeekday(.Wednesday, "thursday", 1);
}

fn testTimeParsing(now: Date, s: []const u8, date: Date) !void {
    const eq = std.testing.expectEqual;

    const parsed = try parseTimelikeDate(now, s);

    try eq(parsed.date.day, date.date.day);
    try eq(parsed.date.month, date.date.month);
    try eq(parsed.time.hour, date.time.hour);
}

test "time parsing" {
    var nowish = try Date.fromDate(2023, 11, 8); // wednesday of nov
    nowish.time.hour = 13;
    nowish.time.minute = 0;
    nowish.time.second = 0;

    try testTimeParsing(nowish, "next week", nowish.shiftDays(5));
    try testTimeParsing(nowish, "tomorrow", nowish.shiftDays(1));
    try testTimeParsing(nowish, "today", nowish);
    try testTimeParsing(nowish, "thursday", nowish.shiftDays(1));
    try testTimeParsing(nowish, "tuesday", nowish.shiftDays(6));
    try testTimeParsing(
        nowish,
        "monday evening",
        nowish.shiftDays(5).shiftHours(6),
    );
    try testTimeParsing(
        nowish,
        "monday 18:00:00",
        nowish.shiftDays(5).shiftHours(5),
    );
    try testTimeParsing(
        nowish,
        "2023-11-09 15:30:00",
        nowish.shiftDays(1).shiftHours(2).shiftMinutes(30),
    );
    try testTimeParsing(
        nowish,
        "10 days",
        nowish.shiftDays(10),
    );
    try testTimeParsing(
        nowish,
        "1 week",
        nowish.shiftDays(7),
    );
}

/// Get the absolute time difference between two `Time`
pub fn absTimeDiff(t1: Time, t2: Time) u64 {
    if (t1.time < t2.time) {
        return t2.time - t1.time;
    }
    return t1.time - t2.time;
}
