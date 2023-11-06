const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{ "todo", "t" };

pub const help = "Add a task to a specified task list.";

pub const extended_help =
    \\Add a task to a specified task list.
    \\
    \\  nkt task
    \\     <text>                short task description / name
    \\     -d/--details str      richer textual details of the task
    \\     --tl/--tasklist name    name of tasklist to write to (default: todo)
    \\     --by date-time        date by which this task must be completed. can
    \\                             be specified in `day-like [hh:mm:ss]` format,
    \\                             where `day-like` is either `YYYY-MM-DD` or
    \\                             a choice of `today`, `tomorrow`, or `WEEKDAY`
    \\     -i/--importance       choice of `low`, `medium`, `high` (default: low)
    \\
;
const Importance = @import("../collections/Topology.zig").Task.Importance;

const parseDateTimeLike = cli.selections.parseDateTimeLike;

text: ?[]const u8 = null,
tasklist: ?[]const u8 = null,
by: ?utils.Date = null,
importance: ?Importance = null,
details: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "tasklist") or arg.is(null, "tl")) {
                if (self.tasklist != null)
                    return cli.CLIErrors.DuplicateFlag;

                self.tasklist = (try itt.getValue()).string;
            } else if (arg.is('d', "details")) {
                if (self.details != null)
                    return cli.CLIErrors.DuplicateFlag;

                self.details = (try itt.getValue()).string;
            } else if (arg.is('i', "importance")) {
                if (self.importance != null)
                    return cli.CLIErrors.DuplicateFlag;

                const val = (try itt.getValue()).string;
                self.importance = std.meta.stringToEnum(Importance, val) orelse
                    return cli.CLIErrors.BadArgument;
            } else if (try parseDateTimeLike(arg, itt, "by")) |date| {
                if (self.by != null) return cli.CLIErrors.DuplicateFlag;
                self.by = date;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (self.text != null) return cli.CLIErrors.TooManyArguments;
            self.text = arg.string;
        }
    }
    self.tasklist = self.tasklist orelse "todo";
    self.importance = self.importance orelse .low;
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    self.text = self.text orelse return cli.CLIErrors.TooFewArguments;
    const name = self.tasklist.?;

    var tasklist = state.getTasklist(self.tasklist.?) orelse
        return cli.SelectionError.NoSuchCollection;

    const by: ?u64 = if (self.by) |b| @intCast(b.toTimestamp()) else null;

    try tasklist.Tasklist.addTask(
        self.text.?,
        .{
            .due = by,
            .importance = self.importance.?,
            .details = self.details orelse "",
        },
    );

    try state.writeChanges();
    try out_writer.print(
        "Written task to '{s}' in tasklist '{s}'\n",
        .{ self.text.?, name },
    );
}
