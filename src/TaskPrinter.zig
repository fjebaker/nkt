const std = @import("std");
const utils = @import("utils.zig");

const TaskPrinter = @import("TaskPrinter.zig");
const Task = @import("collections/Topology.zig").Task;

const FormattedEntry = struct {
    due: []const u8,
    title: []const u8,
    past_due: bool,
};

entries: std.ArrayList(FormattedEntry),
mem: std.heap.ArenaAllocator,
now: utils.Date,

pub fn init(alloc: std.mem.Allocator) TaskPrinter {
    var mem = std.heap.ArenaAllocator.init(alloc);
    var list = std.ArrayList(FormattedEntry).init(alloc);
    return .{ .entries = list, .mem = mem, .now = utils.Date.now() };
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
        return "-";

    const delta = due.sub(self.now);

    const SECONDS_IN_HOUR = 60 * 60;

    const hours = @divFloor(delta.seconds, SECONDS_IN_HOUR);
    const minutes = @divFloor(@rem(delta.seconds, SECONDS_IN_HOUR), 60);

    return try std.fmt.allocPrint(
        alloc,
        "{d}d {d}h {d}m",
        .{ delta.days, hours, minutes },
    );
}

fn pastDue(self: *const TaskPrinter, due_milis: ?u64) bool {
    const due = if (due_milis) |dm|
        utils.Date.fromTimestamp(@intCast(dm))
    else
        return false;

    return self.now.gt(due);
}

pub fn add(self: *TaskPrinter, task: Task) !void {
    var alloc = self.mem.allocator();
    const due = try self.formatDueDate(alloc, task.due);

    try self.entries.append(
        .{
            .due = due,
            .title = task.text,
            .past_due = self.pastDue(task.due),
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
        due_width = @max(item.due.len, due_width);
    }
    return .{ .due = due_width };
}

pub fn drain(self: *const TaskPrinter, writer: anytype) !void {
    const due_column_width = self.columnWidth();

    for (self.entries.items) |item| {
        const due_padding = due_column_width.due - item.due.len;

        _ = try writer.writeAll(item.due);
        try writer.writeByteNTimes(' ', due_padding);

        _ = try writer.writeAll(" - ");
        _ = try writer.writeAll(item.title);
        _ = try writer.writeAll("\n");
    }
}
