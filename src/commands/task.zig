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
    \\     -t/--tasklist name    name of tasklist to write to (default: todo)
    \\     --by date-time        date by which this task must be completed. can
    \\                             be specified in `day-like [hh:mm:ss]` format,
    \\                             where `day-like` is either `YYYY-MM-DD` or
    \\                             a choice of `today`, `tomorrow`, or `WEEKDAY`
    \\     -i/--importance       choice of `low`, `medium`, `high` (default: low)
    \\
;

fn parseDateTimeLike(string: []const u8) !utils.Date {
    var itt = std.mem.tokenize(u8, string, " ");
    const date_like = itt.next() orelse return cli.CLIErrors.BadArgument;
    const time_like = itt.next() orelse "23:59:59";
    if (itt.next()) |_| return cli.CLIErrors.TooManyArguments;

    var day = blk: {
        if (cli.selections.isDate(date_like)) {
            break :blk try utils.toDate(date_like);
        } else if (std.mem.eql(u8, date_like, "today")) {
            break :blk utils.Date.now();
        } else if (std.mem.eql(u8, date_like, "tomorrow")) {
            var today = utils.Date.now();
            break :blk today.shiftDays(1);
        } else return cli.CLIErrors.BadArgument;
    };

    const time = blk: {
        if (cli.selections.isTime(date_like)) {
            break :blk try utils.toTime(time_like);
        } else if (std.mem.eql(u8, time_like, "morning")) {
            break :blk comptime try utils.toTime("08:00:00");
        } else if (std.mem.eql(u8, time_like, "lunch")) {
            break :blk comptime try utils.toTime("13:00:00");
        } else if (std.mem.eql(u8, time_like, "end-of-day")) {
            break :blk comptime try utils.toTime("17:00:00");
        } else if (std.mem.eql(u8, time_like, "evening")) {
            break :blk comptime try utils.toTime("19:00:00");
        } else if (std.mem.eql(u8, time_like, "night")) {
            break :blk comptime try utils.toTime("23:00:00");
        } else break :blk utils.Time{ .hour = 13, .minute = 0, .second = 0 };
    };

    day.time.hour = time.hour;
    day.time.minute = time.minute;
    day.time.second = time.second;

    return day;
}

fn testTimeParsing(s: []const u8, date: utils.Date) !void {
    const eq = std.testing.expectEqual;
    const parsed = try parseDateTimeLike(s);

    try eq(parsed.date.day, date.date.day);
    try eq(parsed.time.hour, date.time.hour);
}

test "time parsing" {
    var nowish = utils.Date.now();
    nowish.time.hour = 13;
    nowish.time.minute = 0;
    nowish.time.second = 0;

    try testTimeParsing("tomorrow", nowish.shiftDays(1));
}

const Importance = @import("../collections/Topology.zig").Task.Importance;

text: ?[]const u8 = null,
tasklist: ?[]const u8 = null,
by: ?utils.Date = null,
importance: ?Importance = null,
details: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('t', "tasklist")) {
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
            } else if (arg.is(null, "by")) {
                if (self.by != null) return cli.CLIErrors.DuplicateFlag;
                const string = (try itt.getValue()).string;
                self.by = try parseDateTimeLike(
                    if (std.mem.eql(u8, string, "tonight"))
                        "today evening"
                    else
                        string,
                );
            }
        } else {
            if (self.text != null) return cli.CLIErrors.TooManyArguments;
            self.text = arg.string;
        }
    }
    self.tasklist = self.tasklist orelse "todo";
    self.importance = self.importance orelse .low;
    self.text = self.text orelse return cli.CLIErrors.TooFewArguments;
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const name = self.tasklist.?;

    var tasklist = state.getTasklist(self.tasklist.?) orelse
        return cli.SelectionError.NoSuchJournal;

    const by: ?u64 = if (self.by) |b| @intCast(b.toTimestamp()) else null;

    try tasklist.Tasklist.addTask(
        self.text.?,
        .{
            .due = by,
            .importance = self.importance.?,
            .details = self.details orelse "",
        },
    );

    try out_writer.print(
        "Written task to '{s}' in tasklist '{s}'\n",
        .{ self.text.?, name },
    );
}
