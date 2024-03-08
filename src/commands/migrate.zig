const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const migration = @import("../migration/migrate.zig");

const Self = @This();

pub const short_help = "Migrate differing versions of nkt's topology";
pub const long_help = short_help;
pub const arguments = cli.ArgumentsHelp(&.{}, .{});

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    _ = try arguments.parseAll(itt);
    return .{};
}

pub fn execute(
    _: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try migration.migratePath(allocator, root.fs.?.root_path);
    try writer.writeAll("Migration complete\n");
}
