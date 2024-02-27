const std = @import("std");

pub const Time = u64;

pub fn timeNow() Time {
    return @intCast(std.time.milliTimestamp());
}
