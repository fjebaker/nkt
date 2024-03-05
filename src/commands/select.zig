const std = @import("std");
const selections = @import("../selections.zig");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");
const Self = @This();

pub const short_help = "Select an item or collection.";
pub const long_help =
    \\Select an item or collection
;

pub const arguments = cli.ArgumentsHelp(
    selections.selectHelp(
        "item",
        "The selection item",
        .{},
    ),
    .{},
);

selection: selections.Selection,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var args = try arguments.parseAll(itt);

    const selection = try selections.fromArgs(
        arguments.ParsedArguments,
        args.item,
        args,
    );

    return .{ .selection = selection };
}

pub fn execute(
    self: *Self,
    _: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try root.load();
    var item = try self.selection.resolveReportError(root);
    defer item.deinit();
    try handleSelection(writer, item);
}

fn handleSelection(writer: anytype, item: selections.Item) !void {
    switch (item) {
        .Day => |*d| {
            try writer.print(
                "Day: {s} [Journal: {s}]\n",
                .{ d.day.name, d.journal.descriptor.name },
            );
        },
        .Task => |t| {
            try writer.print(
                "Task: {s} [Tasklist: {s}]\n",
                .{ t.task.outcome, t.tasklist.descriptor.name },
            );
        },
        else => unreachable,
    }
}
