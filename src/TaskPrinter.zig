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
};

entries: std.ArrayList(FormattedEntry),
mem: std.heap.ArenaAllocator,
now: utils.Date,

pub fn init(alloc: std.mem.Allocator) TaskPrinter {
    var mem = std.heap.ArenaAllocator.init(alloc);
    var list = std.ArrayList(FormattedEntry).init(alloc);
    return .{
        .entries = list,
        .mem = mem,
        .now = utils.Date.now(),
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
        },
    );
}

const Padding = struct {
    due: usize,
    title: usize = 0,
};

fn columnWidth(self: *const TaskPrinter) Padding {
    var due_width: usize = 0;
    for (self.entries.items) |item| {
        due_width = @max(strLen(item.due), due_width);
    }
    return .{ .due = due_width };
}

fn strLen(s: []const u8) usize {
    const alpha = std.ascii.isAlphanumeric;

    var count: usize = 0;
    for (s) |c| {
        if (alpha(c) or c == ' ' or c == '~' or c == '-') {
            count += 1;
        }
    }
    return count;
}

pub fn drain(self: *const TaskPrinter, writer: anytype) !void {
    const due_column_width = self.columnWidth();

    comptime var cham = Chameleon.init(.Auto);
    for (self.entries.items) |item| {
        const due_padding = due_column_width.due - strLen(item.due);

        switch (item.status) {
            .PastDue => {
                try writer.print(cham.redBright().fmt("-{s}"), .{item.due});
            },
            .NearlyDue => {
                try writer.print(cham.yellow().fmt(" {s}"), .{item.due});
            },
            else => {
                try writer.print(" {s}", .{item.due});
            },
        }
        try writer.writeByteNTimes(' ', due_padding);

        _ = try writer.writeAll(" | ");
        _ = try writer.writeAll(item.title);
        _ = try writer.writeAll("\n");
    }
    _ = try writer.writeAll("\n");
}
