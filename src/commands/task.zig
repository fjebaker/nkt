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

pub const Arguments = cli.Arguments(&.{
    .{
        .arg = "outcome",
        .help = "Outcome of the task",
        .required = true,
    },
    .{
        .arg = "action",
        .help = "(Next) Action that needs to be taken.",
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
        .help = "Choice of `low`, `medium`, and `high`",
        .default = "low",
    },
});

args: Arguments.Parsed,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});
    return .{ .args = args };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    _: anytype,
    _: commands.Options,
) !void {
    try root.load();
    const now = time.Time.now();
    const tl_name = self.args.tasklist orelse root.info.default_tasklist;

    var tl = if (try root.getTasklist(tl_name)) |tl|
        tl
    else {
        return cli.throwError(
            Root.Error.NoSuchCollection,
            "No tasklist named '{s}'",
            .{tl_name},
        );
    };

    root.markModified(tl.descriptor, .CollectionTasklist);

    const hash = Tasklist.hash(.{
        .outcome = self.args.outcome,
        .action = self.args.action,
    });

    const total_string = try std.mem.join(
        allocator,
        " ",
        &.{ self.args.outcome, self.args.action orelse "" },
    );
    defer allocator.free(total_string);

    // parse the tags from the outcome and action
    const task_tags = try utils.parseAndAssertValidTags(
        allocator,
        root,
        total_string,
        &.{},
    );
    defer allocator.free(task_tags);

    const new_task: Tasklist.Task = .{
        .outcome = self.args.outcome,
        .action = self.args.action,
        .details = self.args.details,
        .hash = hash,
        .created = now,
        .modified = now,
        .due = try utils.parseDue(now, self.args.due),
        .importance = try utils.parseImportance(self.args.importance),
        .tags = task_tags,
    };

    tl.addNewTask(new_task) catch |err| {
        if (err == Tasklist.Error.DuplicateTask) {
            return cli.throwError(
                err,
                "Task with same hash already exists: {x}",
                .{new_task.hash},
            );
        }
        return err;
    };
    try root.writeChanges();
}
