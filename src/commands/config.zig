const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");
const time = @import("../topology/time.zig");

const Self = @This();

const options = @import("options");

pub const short_help = "View and modify the configuration of nkt";
pub const long_help = short_help;

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    if (try itt.next()) |_| try cli.throwError(
        cli.CLIErrors.TooManyArguments,
        "Expected no arguments",
        .{},
    );
    return .{};
}

pub fn execute(
    _: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    out_writer: anytype,
    opts: commands.Options,
) !void {
    const now = try opts.tz.formatTime(allocator, time.Time.now());
    defer allocator.free(now);
    try out_writer.print(
        \\nkt version            : {d}.{d}.{d}
        \\nkt revision           : {s}
        \\nkt schema version     : {s}
        \\root directory         : {s}
        \\local time             : {s}
        \\
    , .{
        options.version.major,
        options.version.minor,
        options.version.patch,
        options.git_hash orelse "[none]",
        Root.schemaVersion(),
        root.fs.?.root_path,
        now,
    });
}
