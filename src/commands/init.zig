const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");

const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "(Re)Initialize the home directory structure.";
pub const long_help = short_help;

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
    // TODO: add a prompt to check if the home directory is correct
    try root.addInitialCollections();
    try root.createFilesystem(opts.tz);
    try out_writer.print(
        "Home directory initialized: '{s}'\n",
        .{root.fs.?.root_path},
    );
}
