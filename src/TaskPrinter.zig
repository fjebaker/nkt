const std = @import("std");
const utils = @import("utils.zig");
const Chameleon = @import("chameleon").Chameleon;

const TaskPrinter = @import("TaskPrinter.zig");
const Task = @import("collections/Topology.zig").Task;

const Status = enum { PastDue, NearlyDue, NoStatus };

const FormattedEntry = struct {
    due: []const u8,
    title: []const u8,
    status: Status,
    importance: Task.Importance,
};

entries: std.ArrayList(FormattedEntry),
mem: std.heap.ArenaAllocator,
now: utils.Date,
pretty: bool,

pub fn init(alloc: std.mem.Allocator, pretty: bool) TaskPrinter {
    var mem = std.heap.ArenaAllocator.init(alloc);
    var list = std.ArrayList(FormattedEntry).init(alloc);
    return .{
        .entries = list,
        .mem = mem,
        .now = utils.Date.now(),
        .pretty = pretty,
    };
}

pub fn deinit(self: *TaskPrinter) void {
    self.mem.deinit();
    self.entries.deinit();
    self.* = undefined;
}

fn formatDueDate(
    self: *const TaskPrinter,
    alloc: std.mem.Allocator,
    due_milis: ?u64,
) ![]const u8 {
    const due = if (due_milis) |dm|
        utils.Date.fromTimestamp(@intCast(dm))
    else
        return "";

    const overdue = due.lt(self.now);

    const delta = if (overdue)
        self.now.sub(due)
    else
        due.sub(self.now);

    const SECONDS_IN_HOUR = 60 * 60;

    const hours: u32 = @intCast(@divFloor(delta.seconds, SECONDS_IN_HOUR));
    const minutes: u32 = @intCast(@divFloor(@rem(delta.seconds, SECONDS_IN_HOUR), 60));
    const days: u32 = @abs(delta.days);

    return try std.fmt.allocPrint(
        alloc,
        " {d: >3}d {d:0>2}h {d:0>2}m",
        .{ days, hours, minutes },
    );
}

fn pastDue(self: *const TaskPrinter, due_milis: ?u64) Status {
    const due = if (due_milis) |dm|
        utils.Date.fromTimestamp(@intCast(dm))
    else
        return .NoStatus;

    if (self.now.gt(due)) return .PastDue;
    if (due.sub(self.now).days < 1) return .NearlyDue;
    return .NoStatus;
}

pub fn add(self: *TaskPrinter, task: Task) !void {
    var alloc = self.mem.allocator();
    const due = try self.formatDueDate(alloc, task.due);

    try self.entries.append(
        .{
            .due = due,
            .title = task.title,
            .status = self.pastDue(task.due),
            .importance = task.importance,
        },
    );
}

const Padding = struct {
    due: usize,
    title: usize,
};

fn columnWidth(self: *const TaskPrinter) Padding {
    var due_width: usize = 0;
    var title_width: usize = 0;
    for (self.entries.items) |item| {
        due_width = @max(strLen(item.due), due_width);
        title_width = @max(strLen(item.title), title_width);
    }
    return .{ .due = due_width, .title = title_width };
}

fn strLen(s: []const u8) usize {
    return s.len;
}

pub fn drain(self: *TaskPrinter, writer: anytype) !void {
    const col_widths = self.columnWidth();

    _ = try writer.writeAll("\n");
    for (0.., self.entries.items) |i, item| {
        const index = self.entries.items.len - 1 - i;
        try printTask(index, item, col_widths, writer, self.pretty);
        _ = try writer.writeAll("\n");
    }
    _ = try writer.writeAll("\n");
}

fn printTask(
    index: usize,
    entry: FormattedEntry,
    padding: Padding,
    writer: anytype,
    pretty: bool,
) !void {
    comptime var cham = Chameleon.init(.Auto);
    if (pretty) try writeColour(cham.dim(), writer, .Open);
    try writer.print(" {d: >3}", .{index});
    if (pretty) try writeColour(cham.dim(), writer, .Close);

    try writer.writeByteNTimes(' ', padding.due - strLen(entry.due));

    if (pretty) try duePretty(entry.status, writer, .Open);
    try writer.print(" {s}", .{entry.due});
    if (pretty) try duePretty(entry.status, writer, .Close);

    _ = try writer.writeAll(" | ");

    if (pretty) try importancePretty(entry.importance, writer, .Open);
    try writer.print(" {s}", .{entry.title});
    if (pretty) try importancePretty(entry.importance, writer, .Close);
}

fn writeColour(comptime c: Chameleon, writer: anytype, which: OpenClose) !void {
    const open = switch (which) {
        .Open => true,
        .Close => false,
    };
    _ = try writer.writeAll(if (open) c.open else c.close);
}

const OpenClose = enum { Open, Close };
fn duePretty(status: Status, writer: anytype, which: OpenClose) !void {
    const open = switch (which) {
        .Open => true,
        .Close => false,
    };

    comptime var cham = Chameleon.init(.Auto);
    switch (status) {
        .PastDue => {
            const c = cham.bold().redBright();
            _ = try writer.writeAll(if (open) c.open else c.close);
        },
        .NearlyDue => {
            const c = cham.yellow();
            _ = try writer.writeAll(if (open) c.open else c.close);
        },
        else => {},
    }
}

fn importancePretty(importance: Task.Importance, writer: anytype, which: OpenClose) !void {
    const open = switch (which) {
        .Open => true,
        .Close => false,
    };

    comptime var cham = Chameleon.init(.Auto);
    switch (importance) {
        .high => {
            const c = cham.yellow();
            _ = try writer.writeAll(if (open) c.open else c.close);
        },
        .urgent => {
            const c = cham.bold().redBright();
            _ = try writer.writeAll(if (open) c.open else c.close);
        },
        else => {},
    }
}
