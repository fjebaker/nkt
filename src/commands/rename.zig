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
        arguments.Parsed,
        args.from,
        args,
        "from-",
    );
    const to = try selections.fromArgsPrefixed(
        arguments.Parsed,
        args.to,
        args,
        "to-",
    );

    return .{ .from = from, .to = to };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();

    var from_item = try self.from.resolveReportError(root, opts.tz);
    defer from_item.deinit();

    if (try self.to.resolveOrNull(root, opts.tz)) |to_item| {
        _ = to_item;
        unreachable;
    } else {
        const to_name = self.to.selector.?.ByName;
        switch (from_item) {
            .Note => |*n| {
                const old_name = n.note.name;
                _ = try n.directory.rename(old_name, to_name);
                root.markModified(n.directory.descriptor, .CollectionDirectory);
                try root.writeChanges();
                try writer.print(
                    "Moved '{s}' [directory: '{s}'] -> '{s}' [directory: '{s}']\n",
                    .{
                        old_name, n.directory.descriptor.name,
                        to_name,  n.directory.descriptor.name,
                    },
                );
            },
            .Entry, .Day => {
                try cli.throwError(
                    error.InvalidSelection,
                    "Cannot move entries or days of journals.",
                    .{},
                );
                unreachable;
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

    _ = allocator;
}
