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

pub const short_help = "Modify attributes of entries, notes, chains, or tasks.";
pub const long_help = short_help;

pub const Arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{.{
    .arg = "what",
    .help = "May be one of 'done', 'archive', 'todo'",
    .required = true,
}} ++
    selections.selectHelp(
        "item",
        "The item to edit (see `help select`).",
        .{ .required = false },
    ) ++
    &[_]cli.ArgumentDescriptor{
        .{
            .arg = "-c/--chain chain",
            .help = "The chain to apply to",
            .completion = "{compadd $(nkt completion list --collection chains)}",
        },
        .{
            .arg = "--due datelike",
            .help = "Date by which this task must be completed. See `help dates` for format description (default: no due date).",
        },
        .{
            .arg = "-i/--importance imp",
            .help = "Choice of `low`, `medium`, and `high`",
            .default = "low",
            .completion = "(low medium high)",
        },
    });

const SetVerbs = enum { todo, archive, done, alias };

const SetSelection = union(enum) {
    Item: struct {
        what: SetVerbs,
        selection: selections.Selection,
        due: ?time.Time,
        importance: ?Tasklist.Importance,
    },
    Chain: struct {
        what: SetVerbs,
        name: []const u8,
    },
};

selection: SetSelection,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});

    const what = std.meta.stringToEnum(SetVerbs, args.what) orelse {
        try cli.throwError(
            cli.CLIErrors.BadArgument,
            "Unrecognized verb '{s}'",
            .{args.what},
        );
        unreachable;
    };

    if (args.item) |_| {
        if (args.chain != null) {
            try cli.throwError(
                error.AmbiguousSelection,
                "Cannot select both an item and a chain",
                .{},
            );
        }
        const selection = try selections.fromArgs(
            Arguments.Parsed,
            args.item,
            args,
        );

        const now = time.Time.now();

        const due = try utils.parseDue(now, args.due);
        const importance = try utils.parseImportance(args.importance);

        return .{ .selection = .{ .Item = .{
            .what = what,
            .selection = selection,
            .due = due,
            .importance = importance,
        } } };
    } else {
        if (args.chain == null) {
            try cli.throwError(
                cli.CLIErrors.TooFewArguments,
                "No item or chain selected.",
                .{},
            );
        }

        return .{ .selection = .{ .Chain = .{
            .what = what,
            .name = args.chain.?,
        } } };
    }
}

pub fn execute(
    self: *Self,
    _: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try root.load();

    switch (self.selection) {
        .Chain => |c| {
            switch (c.what) {
                .done => {},
                else => {
                    return cli.throwError(
                        cli.CLIErrors.BadArgument,
                        "Cannot use verb '{s}' on chains.",
                        .{@tagName(c.what)},
                    );
                },
            }
            var chains = try root.getChainList();
            const index = chains.getIndexByNameOrAlias(c.name) orelse {
                return cli.throwError(
                    error.NoSuchCollection,
                    "No chain with name or alias '{s}'",
                    .{c.name},
                );
            };
            if (chains.isChainComplete(index)) {
                return cli.throwError(
                    error.ChainAlreadyComplete,
                    "Chain '{s}' has already been marked as complete today.",
                    .{c.name},
                );
            }
            try chains.addCompletionTime(index, time.Time.now());
            try root.writeChains();

            try writer.print("Chain '{s}' marked as complete\n", .{c.name});
        },
        .Item => |*s| {
            const item = try s.selection.resolveReportError(root);
            var task = item.Task;

            var ptr = task.tasklist.getTaskByHashPtr(task.task.hash).?;
            switch (s.what) {
                .done => {
                    try updateTaskField(
                        writer,
                        ptr,
                        "done",
                        Tasklist.Error.AlreadyDone,
                    );
                },
                .archive => {
                    try updateTaskField(
                        writer,
                        ptr,
                        "archived",
                        Tasklist.Error.AlreadyArchived,
                    );
                },
                .todo => {
                    ptr.archived = null;
                    ptr.done = null;

                    if (s.due) |due| ptr.due = due;
                    if (s.importance) |importance| ptr.importance = importance;

                    try writer.print(
                        "Set '{s}' (/{x}) marked as 'todo'.\n",
                        .{ task.task.outcome, task.task.hash },
                    );
                },
                .alias => unreachable,
            }
            root.markModified(task.tasklist.descriptor, .CollectionTasklist);
            try root.writeChanges();
        },
    }
}

fn updateTaskField(
    writer: anytype,
    task: *Tasklist.Task,
    comptime field: []const u8,
    comptime err: anyerror,
) !void {
    if (@field(task, field) != null) {
        return cli.throwError(
            err,
            "Task '{s}' (/{x}) already marked as '{s}'",
            .{ task.outcome, task.hash, field },
        );
    }

    @field(task, field) = time.Time.now();

    try writer.print(
        "Set '{s}' (/{x}) marked as '{s}'.\n",
        .{ task.outcome, task.hash, field },
    );
}
