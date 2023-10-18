const std = @import("std");

pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).ErrorSet.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(anyerror, e.name);
    }
    return null;
}

pub fn now() u64 {
    return @intCast(std.time.timestamp());
}
