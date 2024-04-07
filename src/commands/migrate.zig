const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "Migrate differing versions of nkt's topology";
pub const long_help = short_help;
pub const arguments = cli.Arguments(&.{});

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    _ = args;
    return .{};
}

pub fn execute(
    _: *Self,
    _: std.mem.Allocator,
    root: *Root,
    _: anytype,
    _: commands.Options,
) !void {
    // load and write all files
    try root.load();
    for (root.info.journals) |jrnl| {
        var journal = (try root.getJournal(jrnl.name)).?;
        for (journal.info.days) |day| {
            const d = journal.getDay(day.name).?;
            _ = try journal.getEntries(d);
        }
        try journal.writeDays();

        root.markModified(jrnl, .CollectionJournal);
    }
    for (root.info.directories) |dir| {
        _ = (try root.getDirectory(dir.name)).?;
        root.markModified(dir, .CollectionDirectory);
    }
    for (root.info.tasklists) |tl| {
        _ = (try root.getTasklist(tl.name)).?;
        root.markModified(tl, .CollectionTasklist);
    }
    try root.writeChanges();
    try root.writeTags();
    try root.writeChains();
}
