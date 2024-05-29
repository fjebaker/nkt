const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Journal = @import("../topology/Journal.zig");
const Tasklist = @import("../topology/Tasklist.zig");
const Root = @import("../topology/Root.zig");

const colors = @import("../colors.zig");

const Self = @This();

pub const alias = [_][]const u8{"rm"};

pub const short_help = "Remove items, tags, or entire collections themselves.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "selection",
    "Selected item or collection to remove (see `help select` for the formatting).",
    .{ .required = true },
));

selection: selections.Selection,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    const selection = try selections.fromArgs(
        arguments.Parsed,
        args.selection,
        args,
    );
    return .{ .selection = selection };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    _: anytype,
    _: commands.Options,
) !void {
    try root.load();
    var item = try self.selection.resolveReportError(root);

    var writer = std.io.getStdOut().writer();

    switch (item) {
        .Entry => |*e| {
            if (try utils.promptNo(
                allocator,
                writer,
                "Remove entry '{s}' in journal '{s}'?",
                .{ e.entry.text, e.journal.descriptor.name },
            )) {
                try e.journal.removeEntryFromDay(e.day, e.entry);
                try e.journal.writeDays();
                try writer.writeAll("Entry removed.\n");
            }
        },
        .Day => |*d| {
            if (try utils.promptNo(
                allocator,
                writer,
                "Remove ENTIRE day '{s}' in journal '{s}'?",
                .{ d.day.name, d.journal.descriptor.name },
            )) {
                try d.journal.removeDay(d.day);
                root.markModified(
                    d.journal.descriptor,
                    .CollectionJournal,
                );
                try root.writeChanges();
                try writer.writeAll("Day removed.\n");
            }
        },
        .Task => |*t| {
            if (try utils.promptNo(
                allocator,
                writer,
                "Remove task '{s}' (/{x}) in tasklist '{s}'?",
                .{ t.task.outcome, t.task.hash, t.tasklist.descriptor.name },
            )) {
                try t.tasklist.removeTask(t.task);
                root.markModified(
                    t.tasklist.descriptor,
                    .CollectionTasklist,
                );
                try root.writeChanges();
                try writer.writeAll("Entry removed.\n");
            }
        },
        .Note => |*n| {
            if (try utils.promptNo(
                allocator,
                writer,
                "Remove note '{s}' in directory '{s}'?",
                .{ n.note.name, n.directory.descriptor.name },
            )) {
                try n.directory.removeNote(n.note);
                root.markModified(
                    n.directory.descriptor,
                    .CollectionDirectory,
                );
                try root.writeChanges();
                try writer.writeAll("Note removed.\n");
            }
        },
        // TODO: implement these
        .Collection => {},
    }
}
