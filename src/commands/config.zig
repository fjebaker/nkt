const std = @import("std");
const cli = @import("../cli.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const help = "View and modify the configuration of nkt";

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    try itt.assertNoArguments();
    return .{};
}

pub fn run(
    _: *Self,
    root: *Root,
    out_writer: anytype,
    _: cli.Options,
) !void {
    try out_writer.print(
        \\nkt schema version     : {s}
        \\root directory         : {s}
        \\
    , .{ Root.schemaVersion(), root.fs.?.root_path });
}
