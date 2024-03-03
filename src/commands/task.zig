const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Tasklist = @import("../topology/Tasklist.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "Add a task to a specified task list.";
pub const long_help = short_help;

pub const arguments = cli.ArgumentsHelp(&.{
    .{
        .arg = "title",
        .help = "Short name or description of the task",
        .required = true,
    },
    .{
        .arg = "--tasklist tasklist",
        .help = "Name of the tasklist to write to (else uses default tasklist).",
    },
    .{
        .arg = "--details info",
        .help = "Optional additional details about the task.",
    },
    .{
        .arg = "--due datelike",
        .help = "Date by which this task must be completed. See `help dates` for format description (default: no due date).",
    },
    .{
        .arg = "-i/--importance imp",
        .help = "Choice of `low`, `medium`, and `high` (default: `low`).",
    },
}, .{});

args: arguments.ParsedArguments,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var args = try arguments.parseAll(itt);
    return .{ .args = args };
}

pub fn execute(
    self: *Self,
    _: std.mem.Allocator,
    root: *Root,
    _: anytype,
    _: commands.Options,
) !void {
    try root.load();
    const now = time.timeNow();
    const tl_name = self.args.tasklist orelse root.info.default_tasklist;

    var tl = if (try root.getTasklist(tl_name)) |tl|
        tl
    else {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No tasklist named '{s}'",
            .{tl_name},
        );
        unreachable;
    };

    defer tl.deinit();

    const new_task: Tasklist.Task = .{
        .title = self.args.title,
        .details = self.args.details,
        .created = now,
        .modified = now,
        .due = try parseDue(now, self.args.due),
        .importance = try parseImportance(self.args.importance),
        .tags = &.{},
    };

    try tl.addNewTask(new_task);
    try root.writeChanges();
}

fn parseImportance(importance: ?[]const u8) !Tasklist.Importance {
    const imp = importance orelse
        return .Low;
    return try Tasklist.Importance.parseFromString(imp);
}

fn parseDue(now: time.Time, due: ?[]const u8) !?time.Time {
    const d = due orelse return null;
    return try time.parseTimelike(now, d);
}
