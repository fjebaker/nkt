const std = @import("std");
const time = @import("time");

pub const Date = time.DateTime;

pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).ErrorSet.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(anyerror, e.name);
    }
    return null;
}

pub fn timezone() comptime_int {
    return std.time.ms_per_hour;
}

pub fn now() u64 {
    return @intCast(std.time.milliTimestamp());
}
