const std = @import("std");
const selections = @import("../selections.zig");
const abstractions = @import("../abstractions.zig");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");
const Self = @This();

pub const short_help = "Select an item or collection.";
pub const long_help =
    \\Select an item or collection. There are a number of different ways that
    \\the selector can resolve items. The collection name can either be provided
    \\with the appropriate flag (e.g. `--directory` or `--journal`), or can be
    \\hinted using the
    \\
    \\    collection_name:selector
    \\
    \\syntax. This syntax is supposed to make querying and fetching items a little
    \\less cumbersome, but can be imprecise. The flag versions can be reliably used
    \\in scripts or in note references to select items.
    \\
    \\## Examples
    \\
    \\Selecting the first task by index:
    \\
    \\    nkt select t0
    \\
    \\Selecting the 5th task in the tasklist "reading"
    \\
    \\    nkt select t5 --tasklist reading
    \\    nkt select reading:t5
    \\
    \\Selecting the note `linux.bash`:
    \\
    \\    nkt select linux.bash
;

pub const Arguments = cli.Arguments(
    selections.selectHelp(
        "item",
        "The main selection query.",
        .{ .required = false },
    ),
);

selection: selections.Selection,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});

    const selection = try selections.fromArgs(
        Arguments.Parsed,
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
    const item = try self.selection.resolveReportError(root);
    try handleSelection(writer, item);
}

fn handleSelection(writer: anytype, item: abstractions.Item) !void {
    switch (item) {
        .Day => |d| {
            try writer.print(
                "Day: {s} [Journal: {s}]\n",
                .{ d.day.name, d.journal.descriptor.name },
            );
        },
        .Entry => |e| {
            // TODO: get the day name too
            try writer.print(
                "Entry: '{s}' [Journal: {s}]\n",
                .{ e.entry.text, e.journal.descriptor.name },
            );
        },
        .Task => |t| {
            try writer.print(
                "Task: {s} [Tasklist: {s}]\n",
                .{ t.task.outcome, t.tasklist.descriptor.name },
            );
        },
        .Note => |n| {
            try writer.print(
                "Note: {s} [Directory: {s}]\n",
                .{ n.note.name, n.directory.descriptor.name },
            );
        },
        .Collection => |c| switch (c) {
            .directory => |d| {
                try writer.print(
                    "Collection: {s} [type: directory]\n",
                    .{d.descriptor.name},
                );
            },
            .journal => |j| {
                try writer.print(
                    "Collection: {s} [type: journal]\n",
                    .{j.descriptor.name},
                );
            },
            .tasklist => |t| {
                try writer.print(
                    "Collection: {s} [type: tasklist]\n",
                    .{t.descriptor.name},
                );
            },
        },
    }
}
