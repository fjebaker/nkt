const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");
const time = @import("../topology/time.zig");

const Self = @This();

pub const short_help = "View and modify the configuration of nkt";
pub const long_help = short_help;
pub const argument_help = "";

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    try itt.assertNoArguments();
    return .{};
}

pub fn execute(
    _: *Self,
    _: std.mem.Allocator,
    root: *Root,
    out_writer: anytype,
    opts: commands.Options,
) !void {
    try out_writer.print(
        \\nkt schema version     : {s}
        \\root directory         : {s}
        \\timezone               : {s}
        \\local time             : {s}
        \\
    , .{
        Root.schemaVersion(),
        root.fs.?.root_path,
        opts.tz.tz.name,
        try time.formatDateTimeBuf(opts.tz.localTimeNow()),
    });
}
