const std = @import("std");
const colors = @import("colors.zig");
const utils = @import("utils.zig");
const Farbe = colors.Farbe;

const time = @import("topology/time.zig");
const tags = @import("topology/tags.zig");
const Tasklist = @import("topology/Tasklist.zig");
const Task = Tasklist.Task;

const FormatPrinter = @import("FormatPrinter.zig");

const Self = @This();

const Status = Tasklist.Status;

/// Store information relevant to the task
const FormattedTask = struct {
    due: []const u8,
    pretty_date: ?[]const u8,
    task: Task,
    status: Status,
    index: ?usize,
};

const PrintOptions = struct {
    tz: time.TimeZone,
    pretty: bool = false,
    full_hash: bool = false,
    tag_descriptors: ?[]const tags.Tag.Descriptor = null,
};

entries: std.ArrayList(FormattedTask),
mem: std.heap.ArenaAllocator,
now: time.Time,
opts: PrintOptions,

pub fn init(alloc: std.mem.Allocator, opts: PrintOptions) Self {
    const mem = std.heap.ArenaAllocator.init(alloc);
    const list = std.ArrayList(FormattedTask).init(alloc);
    return .{
        .entries = list,
        .mem = mem,
        .now = time.timeNow(),
        .opts = opts,
    };
}

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.entries.deinit();
    self.* = undefined;
}

fn formatDueDate(
    self: *const Self,
    alloc: std.mem.Allocator,
    due_time: ?u64,
) ![]const u8 {
    const due = if (due_time) |t|
        time.dateFromTime(t)
    else
        return "";

    const now = time.dateFromTime(self.now);

    const overdue = due.lt(now);

    const delta = if (overdue)
        now.sub(due)
    else
        due.sub(now);

    const SECONDS_IN_HOUR = 60 * 60;

    const hours: u32 = @intCast(@divFloor(delta.seconds, SECONDS_IN_HOUR));
    const minutes: u32 = @intCast(@divFloor(@rem(delta.seconds, SECONDS_IN_HOUR), 60));
    const days: u32 = @abs(delta.days);

    const indicator = if (overdue) "-" else " ";

    return try std.fmt.allocPrint(
        alloc,
        "{s} {d: >3}d {d:0>2}h {d:0>2}m",
        .{ indicator, days, hours, minutes },
    );
}

fn formatTime(tz: time.TimeZone, t: time.Time) ![]const u8 {
    const local = tz.makeLocal(time.dateFromTime(t));
    return &try time.formatDateBuf(local);
}

fn formatTimeAlloc(
    allocator: std.mem.Allocator,
    tz: time.TimeZone,
    t: time.Time,
) ![]const u8 {
    return try allocator.dupe(
        u8,
        try formatTime(tz, t),
    );
}

pub fn add(self: *Self, task: Task, index: ?usize) !void {
    const alloc = self.mem.allocator();
    const due = try self.formatDueDate(alloc, task.due);

    // make date pretty
    const pretty_date: ?[]const u8 =
        if (task.done) |cmpl|
        try formatTimeAlloc(alloc, self.opts.tz, cmpl)
    else if (task.archived) |arch|
        try formatTimeAlloc(alloc, self.opts.tz, arch)
    else
        null;

    try self.entries.append(
        .{
            .due = due,
            .status = task.getStatus(self.now),
            .pretty_date = pretty_date,
            .task = task,
            .index = index,
        },
    );
}

const Padding = struct {
    due: usize,
    outcome: usize,
};

fn columnWidth(self: *const Self) Padding {
    var due_width: usize = 0;
    var outcome_width: usize = 0;
    for (self.entries.items) |item| {
        due_width = @max(strLen(item.due), due_width);
        outcome_width = @max(strLen(item.task.outcome), outcome_width);
    }
    return .{ .due = due_width, .outcome = outcome_width };
}

fn strLen(s: []const u8) usize {
    return s.len;
}

pub fn drain(
    self: *Self,
    writer: anytype,
    details: bool,
) !void {
    var fp = FormatPrinter.init(
        self.mem.child_allocator,
        .{
            .pretty = self.opts.pretty,
            .tag_descriptors = self.opts.tag_descriptors,
        },
    );
    defer fp.deinit();

    const col_widths = self.columnWidth();

    try fp.addText("\n", .{});

    var previous: ?FormattedTask = null;
    for (self.entries.items) |item| {
        if (needsSeperator(previous, item)) {
            try fp.addText("\n", .{});
        }
        try printTask(&fp, item, col_widths, details, self.opts.full_hash);
        try fp.addText("\n", .{});
        previous = item;
    }
    try fp.addText("\n", .{});

    try fp.drain(writer);
}

fn needsSeperator(prev: ?FormattedTask, current: FormattedTask) bool {
    const p = prev orelse return false;

    const p_due = p.task.due orelse {
        // print spacer between those we due dates and those without
        return current.task.due != null;
    };

    const c_due = current.task.due.?;

    // if they are both overdue, no gap
    if (p.status == .PastDue and current.status == .PastDue) return false;

    const t_diff = time.absTimeDiff(p_due, c_due);
    return t_diff > std.time.ms_per_day;
}

fn printTask(
    fp: *FormatPrinter,
    entry: FormattedTask,
    padding: Padding,
    details: bool,
    full_hash: bool,
) !void {
    const allocator = fp.mem.allocator();

    if (entry.index) |index| {
        try fp.addFmtText(
            " {d: >3}",
            .{index},
            .{ .fmt = colors.DIM.runtime(allocator) },
        );
    } else {
        try fp.addText("    ", .{});
    }

    const string = entry.pretty_date orelse entry.due;
    try fp.addNTimes(' ', 1 + padding.due -| strLen(string), .{});

    const indicator: []const u8 = switch (entry.status) {
        .Archived => "A",
        .Done => "✓",
        .NearlyDue => "*",
        .PastDue => "!",
        else => " ",
    };
    const due_color = switch (entry.status) {
        .PastDue => colors.RED.bold(),
        .NearlyDue => colors.YELLOW,
        .Done => colors.GREEN,
        .Archived => colors.DIM,
        else => null,
    };
    try fp.addFmtText(
        "{s} {s}",
        .{ string, indicator },
        .{ .fmt = if (due_color) |c| c.fixed() else null },
    );

    try fp.addText(" | ", .{});

    if (full_hash) {
        try fp.addFmtText(
            "/{x:0>16}",
            .{entry.task.hash},
            .{ .fmt = colors.DIM.fixed() },
        );
    } else {
        try fp.addFmtText(
            "/{x:0>5}",
            .{@as(u20, @intCast(utils.getMiniHash(entry.task.hash, 5)))},
            .{ .fmt = colors.DIM.fixed() },
        );
    }

    try fp.addText(" | ", .{});

    const importance: []const u8 = switch (entry.task.importance) {
        .High => "*",
        .Urgent => "!",
        else => " ",
    };
    const importance_color = switch (entry.task.importance) {
        .High => colors.YELLOW,
        .Urgent => colors.RED.bold(),
        else => null,
    };

    try fp.addFmtText(
        "{s} {s}",
        .{ importance, entry.task.outcome },
        .{ .fmt = if (importance_color) |c| c.fixed() else null },
    );
    if (entry.task.action) |act| {
        try fp.addFmtText(
            " - {s}",
            .{act},
            .{ .fmt = colors.DIM.fixed() },
        );
    }

    const has_details = if (entry.task.details) |d| d.len > 0 else false;

    const text_pad: usize = p: {
        if (!details and has_details) {
            try fp.addText(" [+]", .{
                .fmt = colors.DIM.fixed(),
            });
            break :p 4;
        } else break :p 0;
    };
    _ = text_pad;

    // if (details and has_details) {
    //     try printDetails(entry.task.details, writer, padding, pretty);
    // }
}

const STRIDE = 70;
fn printDetails(
    details: []const u8,
    writer: anytype,
    padding: Padding,
    pretty: bool,
) !void {
    _ = pretty;
    // if (pretty) try writeColour(cham.dim(), writer, .Open);
    const indent = padding.due + 12;

    var lines = std.mem.split(u8, std.mem.trim(u8, details, "\n"), "\n");

    while (lines.next()) |line| {
        var itt = std.mem.window(u8, line, STRIDE, STRIDE);
        while (itt.next()) |chunk| {
            _ = try writer.writeAll("\n");
            _ = try writer.writeByteNTimes(' ', indent);
            _ = try writer.writeAll(". ");
            _ = try writer.writeAll(chunk);
        }
    }

    // if (pretty) try writeColour(cham.dim(), writer, .Close);
}
