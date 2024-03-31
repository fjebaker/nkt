const std = @import("std");
const time = @import("time");
const chrono = @import("chrono");

pub const Error = error{DateTooShort};

/// The type representing times in the topology: an integer counting
/// miliseconds since epoch in UTC
pub const Time = u64;

pub const Timestamp = time.datetime.Time;
pub const Date = time.datetime.Datetime;
pub const Weekday = time.datetime.Weekday;

pub const TimeZone = struct {
    tz: time.datetime.Timezone,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TimeZone) void {
        self.allocator.free(self.tz.name);
        self.* = undefined;
    }

    /// Format a UTC date with the given timezone for saving to disk or
    /// displaying Caller owns memory
    pub fn formatTime(self: TimeZone, allocator: std.mem.Allocator, t: Time) ![]const u8 {
        const adjusted = self.makeLocal(dateFromTime(t));
        const date_time = try formatDateTimeBuf(adjusted);
        const offset = @divFloor(self.tz.offset, 60);
        return try std.fmt.allocPrint(allocator, "{s} {s} (GMT{s}{d})", .{
            date_time,
            self.tz.name,
            if (offset > 0) "+" else "-",
            @abs(offset),
        });
    }

    /// Initialize a UTC timezone
    pub fn initUTC(allocator: std.mem.Allocator) !TimeZone {
        const utc_copy = try allocator.dupe(u8, "UTC");
        const tz = time.datetime.Timezone.create(utc_copy, 0);
        return .{
            .tz = tz,
            .allocator = allocator,
        };
    }

    /// Convert a given date to a local date
    pub fn makeLocal(self: TimeZone, date: Date) Date {
        return date.shiftTimezone(&self.tz);
    }

    /// Convert a given local date to UTC date
    pub fn makeUTC(self: TimeZone, date: Date) Date {
        var to_utc = self.tz;
        to_utc.offset = -to_utc.offset;
        return date.shiftTimezone(&to_utc);
    }

    /// Get the local time now
    pub fn localTimeNow(self: TimeZone) Date {
        return self.makeLocal(dateFromTime(timeNow()));
    }
};

/// Get the timezone
pub fn getTimeZone(allocator: std.mem.Allocator) !TimeZone {
    switch (@import("builtin").os.tag) {
        .linux, .macos => {}, // ok
        else => @compileError("Timezone not inferrable for this OS in current version"),
    }

    var tzdb = try chrono.tz.DataBase.init(allocator);
    defer tzdb.deinit();

    const timezone = try tzdb.getLocalTimeZone();

    const timestamp_utc = std.time.timestamp();
    const local_offset = timezone.offsetAtTimestamp(timestamp_utc) orelse 0;
    const designation = timezone.designationAtTimestamp(timestamp_utc) orelse "NA";

    const tz = time.datetime.Timezone.create(
        try allocator.dupe(u8, designation),
        @intCast(@divFloor(local_offset, 60)), // convert to minutes
    );
    return .{ .tz = tz, .allocator = allocator };
}

/// Get the time now as `Time`
pub fn timeNow() Time {
    return @intCast(std.time.milliTimestamp());
}

/// Get the end of the day `Date` from a `Date`. This is the equivalent to
/// 23:59:59.
pub fn endOfDay(day: Date) Date {
    const second_to_day_end = std.time.s_per_day - @as(
        i64,
        @intFromFloat(day.time.toSeconds()),
    );
    return day.shiftSeconds(second_to_day_end - 1);
}
/// Get the start of the day `Date` from a `Date`. This is the equivalent to
/// 00:00:00.
pub fn startOfDay(day: Date) Date {
    const seconds_to_start: i64 = @intFromFloat(day.time.toSeconds());
    return day.shiftSeconds(-seconds_to_start);
}

/// Turn a `Time` into a `Date`
pub fn dateFromTime(t: Time) Date {
    return Date.fromTimestamp(@intCast(t));
}

/// Get a `Time` from a `Date`
pub fn timeFromDate(date: Date) Time {
    return @intCast(date.toTimestamp());
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

/// Convert a string to a `Date`
pub fn toDate(string: []const u8) !Date {
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
    return dateFromTime(t).shiftDays(
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

    fn optionalTime(c: *Colloquial) !Timestamp {
        const time_like = c.nextOrNull() orelse
            return DEFAULT_TIME;
        return try timeOfDay(time_like);
    }

    pub fn parse(c: *Colloquial) !Date {
        var arg = try c.next();

        if (_eq(arg, "soon")) {
            var prng = std.rand.DefaultPrng.init(timeNow());
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
        } else {
            // predicated
            if (_eq(arg, "today")) {
                return c.setTime(c.now, try c.optionalTime());
            } else if (_eq(arg, "tomorrow")) {
                return c.setTime(
                    c.now.shiftDays(1),
                    try c.optionalTime(),
                );
            } else if (isDate(arg)) {
                const date = try toDate(arg);
                return c.setTime(date, try c.optionalTime());
            }
        }

        // mutual
        if (c.parseWeekday(arg)) |date| {
            return c.setTime(date, try c.optionalTime());
        }

        return error.BadArgument;
    }

    fn parseNextTime(c: *Colloquial) !Date {
        if (c.parseWeekday(try c.next())) |date| {
            _ = date;
        }
    }

    fn parseDate(c: *Colloquial) !Date {
        const arg = c.next();
        if (isDate(arg)) {
            return try toDate(arg);
        } else if (std.mem.eql(u8, arg, "today")) {
            return Date.now();
        } else if (std.mem.eql(u8, arg, "tomorrow")) {
            return c.now().shiftDays(1);
        } else return error.BadArgument;
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

    const TIME_OF_DAY = std.ComptimeStringMap(Timestamp, .{
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
    const itt = std.mem.tokenize(u8, timelike, " ");
    var col = Colloquial{ .tkn = itt, .now = relative };
    return try col.parse();
}

/// Parse a time-like string into a time. See also `Colloquial`. Any relative time-like will be relative to the time in `relative`.
pub fn parseTimelike(relative: Time, timelike: []const u8) !Time {
    const now = dateFromTime(relative);
    const itt = std.mem.tokenize(u8, timelike, " ");
    var col = Colloquial{ .tkn = itt, .now = now };
    const parsed = try col.parse();
    return timeFromDate(parsed);
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
}

/// Get the absolute time difference between two `Time`
pub fn absTimeDiff(t1: Time, t2: Time) Time {
    if (t1 < t2) {
        return t2 - t1;
    }
    return t1 - t2;
}
