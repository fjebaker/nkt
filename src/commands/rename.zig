const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const alias = [_][]const u8{"mv"};

pub const short_help = "Move or rename a note, directory, journal, or tasklist.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "from",
    "The item to move from (see `help select`).",
    .{ .required = true, .flag_prefix = "from-" },
) ++
    selections.selectHelp(
    "to",
    "The item to move to (see `help select`).",
    .{ .required = true, .flag_prefix = "to-" },
));

from: selections.Selection,
to: selections.Selection,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);

    const from = try selections.fromArgsPrefixed(
        "from-",
        arguments.Parsed,
        args.from,
        args,
    );
    const to = try selections.fromArgsPrefixed(
        "to-",
        arguments.Parsed,
        args.to,
        args,
    );

    return .{ .from = from, .to = to };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try root.load();

    var from_item = try self.from.resolveReportError(root);

    if (try self.to.resolveOrNull(root)) |to_item| {
        // TODO:
        std.debug.print(">>> TO: {s}\n", .{try to_item.getName(allocator)});
        unreachable;
    } else {
        const to_name = self.to.selector.?.ByName;
        switch (from_item) {
            .Note => |*n| {
                const old_name = n.note.name;
                if (sameCollection(
                    self.from.collection_name,
                    self.to.collection_name,
                )) {
                    _ = try n.directory.rename(old_name, to_name);
                    root.markModified(n.directory.descriptor, .CollectionDirectory);
                } else {
                    var to_dir = (try root.getDirectory(self.to.collection_name.?)) orelse {
                        return cli.throwError(
                            error.NoSuchCollection,
                            "Directory '{s}' does not exists.",
                            .{self.to.collection_name.?},
                        );
                    };
                    // TODO: what about if there are assets?
                    var new_note = n.note;
                    new_note.path = try adjustPath(to_dir, new_note.path);

                    try to_dir.addNewNote(new_note);
                    try root.fs.?.move(n.note.path, new_note.path);
                    try n.directory.removeNote(n.note);

                    root.markModified(n.directory.descriptor, .CollectionDirectory);
                    root.markModified(to_dir.descriptor, .CollectionDirectory);
                }
                try root.writeChanges();
                try writer.print(
                    "Moved '{s}' [directory: '{s}'] -> '{s}' [directory: '{s}']\n",
                    .{
                        old_name,
                        n.directory.descriptor.name,
                        to_name,
                        self.to.collection_name orelse n.directory.descriptor.name,
                    },
                );
            },
            .Entry, .Day => {
                return cli.throwError(
                    error.InvalidSelection,
                    "Cannot move entries or days of journals.",
                    .{},
                );
            },
            .Task => |*t| {
                const old_name = t.task.outcome;
                _ = try t.tasklist.rename(t.task, to_name);
                root.markModified(t.tasklist.descriptor, .CollectionTasklist);
                try root.writeChanges();
                try writer.print(
                    "Moved '{s}' [tasklist: '{s}'] -> '{s}' [tasklist: '{s}']\n",
                    .{
                        old_name, t.tasklist.descriptor.name,
                        to_name,  t.tasklist.descriptor.name,
                    },
                );
            },
            else => unreachable,
        }
    }
}

fn sameCollection(from: ?[]const u8, to: ?[]const u8) bool {
    if (from == null and to == null) return true;
    const f = from orelse return false;
    // if to is not set, we use the same directory
    const t = to orelse return true;
    return std.mem.eql(u8, t, f);
}

fn adjustPath(dir: Root.Directory, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    const dirname = std.fs.path.dirname(dir.descriptor.path).?;

    return try std.fs.path.join(dir.allocator, &.{
        dirname,
        base,
    });
}
