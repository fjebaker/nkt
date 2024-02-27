const std = @import("std");
const cli = @import("../cli.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const help = "View and modify the configuration of nkt";

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    if (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        return cli.CLIErrors.TooManyArguments;
    }

    return .{};
}

pub fn run(
    _: *Self,
    root: *Root,
    out_writer: anytype,
) !void {
    try out_writer.print(
        \\nkt schema version     : {s}
        \\root directory         : {s}
        \\
    , .{ Root.schemaVersion(), root.fs.?.root_path });
}
