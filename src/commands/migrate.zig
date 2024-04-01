const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const migration = @import("../migration/migrate.zig");

const Self = @This();

pub const short_help = "Migrate differing versions of nkt's topology";
pub const long_help = short_help;
pub const arguments = cli.Arguments(&.{
    .{
        .arg = "touch",
        .help = "Touch all files",
    },
});

touch: bool,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    return .{ .touch = args.touch != null };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    if (self.touch) {

        // load and write all files
        try root.load();
        for (root.info.journals) |jrnl| {
            var journal = (try root.getJournal(jrnl.name)).?;
            defer journal.deinit();
            for (journal.info.days) |day| {
                const d = journal.getDay(day.name).?;
                _ = try journal.getEntries(d);
            }
            try journal.writeDays();

            root.markModified(jrnl, .CollectionJournal);
        }
        for (root.info.directories) |dir| {
            var directory = (try root.getDirectory(dir.name)).?;
            defer directory.deinit();
            root.markModified(dir, .CollectionDirectory);
        }
        for (root.info.tasklists) |tl| {
            var tasks = (try root.getTasklist(tl.name)).?;
            defer tasks.deinit();
            root.markModified(tl, .CollectionTasklist);
        }
        try root.writeChanges();
        try root.writeTags();
        try root.writeChains();
    } else {
        try migration.migratePath(
            allocator,
            root.fs.?.root_path,
        );
        try writer.writeAll("Migration complete\n");
    }
}
