const std = @import("std");
const time = @import("time");
const chrono = @import("chrono");

pub const Error = error{DateTooShort};

/// The type representing times in the topology: an integer counting
/// miliseconds since epoch in UTC
pub const Time = u64;

pub const Timestamp = time.datetime.Time;
pub const Date = time.datetime.Datetime;

pub const TimeZone = struct {
    tz: time.datetime.Timezone,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TimeZone) void {
        self.allocator.free(self.tz.name);
        self.* = undefined;
    }

    /// Convert a given date to a local date
    pub fn localDate(self: TimeZone, date: Date) Date {
        return date.shiftTimezone(&self.tz);
    }

    /// Get the local time now
    pub fn localTimeNow(self: TimeZone) Date {
        return self.localDate(dateFromTime(timeNow()));
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

/// Turn a `Time` into a `Date`
pub fn dateFromTime(t: Time) Date {
    return Date.fromTimestamp(@intCast(t));
}

/// Get a `Time` from a `Date`
pub fn timeFromDate(date: Date) Time {
    return @intCast(date.toTimestamp());
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
