const std = @import("std");
const utils = @import("utils.zig");
const Chameleon = @import("chameleon").Chameleon;

const TaskPrinter = @import("TaskPrinter.zig");
const Task = @import("collections/Topology.zig").Task;

const Status = enum { PastDue, NearlyDue, NoStatus, Done };

const FormattedEntry = struct {
    due: []const u8,
    completed: []const u8,
    task: Task,
    status: Status,
    index: ?usize,
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

pub fn add(self: *TaskPrinter, task: Task, index: ?usize) !void {
    var alloc = self.mem.allocator();
    const due = try self.formatDueDate(alloc, task.due);
    const completed: []const u8 = if (task.completed) |cmpl|
        try alloc.dupe(
            u8,
            &try utils.formatDateBuf(utils.dateFromMs(cmpl)),
        )
    else
        "";

    try self.entries.append(
        .{
            .due = due,
            .status = if (task.done) .Done else self.pastDue(task.due),
            .completed = completed,
            .task = task,
            .index = index,
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
        title_width = @max(strLen(item.task.title), title_width);
    }
    return .{ .due = due_width, .title = title_width };
}

fn strLen(s: []const u8) usize {
    return s.len;
}

pub fn drain(self: *TaskPrinter, writer: anytype, details: bool) !void {
    const col_widths = self.columnWidth();

    _ = try writer.writeAll("\n");
    for (self.entries.items) |item| {
        try printTask(item, col_widths, writer, self.pretty, details);
        _ = try writer.writeAll("\n");
    }
    _ = try writer.writeAll("\n");
}

fn printTask(
    entry: FormattedEntry,
    padding: Padding,
    writer: anytype,
    pretty: bool,
    details: bool,
) !void {
    comptime var cham = Chameleon.init(.Auto);
    if (entry.index) |index| {
        if (pretty) try writeColour(cham.dim(), writer, .Open);
        try writer.print(" {d: >3}", .{index});
        if (pretty) try writeColour(cham.dim(), writer, .Close);
    } else {
        try writer.print("    ", .{});
    }

    const string = if (entry.status == .Done) entry.completed else entry.due;
    try writer.writeByteNTimes(' ', 1 + padding.due - strLen(string));

    if (pretty) try duePretty(entry.status, writer, .Open);
    try writer.print("{s}", .{string});
    try printStatusIndicator(entry.status, writer);
    if (pretty) try duePretty(entry.status, writer, .Close);

    _ = try writer.writeAll("|");

    if (pretty) try importancePretty(entry.task.importance, writer, .Open);
    try printImportanceIndicator(entry.task.importance, writer);
    try writer.print("{s}", .{entry.task.title});
    if (pretty) try importancePretty(entry.task.importance, writer, .Close);

    const has_details = entry.task.details.len > 0;

    const text_pad: usize = p: {
        if (!details and has_details) {
            if (pretty) try writeColour(cham.dim(), writer, .Open);
            try printDetailIndicator(writer);
            if (pretty) try writeColour(cham.dim(), writer, .Close);
            break :p 4;
        } else break :p 0;
    };
    _ = text_pad;

    if (details and has_details) {
        try printDetails(entry.task.details, writer, padding, pretty);
    }
}

fn writeColour(comptime c: Chameleon, writer: anytype, which: OpenClose) !void {
    const open = switch (which) {
        .Open => true,
        .Close => false,
    };
    _ = try writer.writeAll(if (open) c.open else c.close);
}

const STRIDE = 70;
fn printDetails(
    details: []const u8,
    writer: anytype,
    padding: Padding,
    pretty: bool,
) !void {
    comptime var cham = Chameleon.init(.Auto);
    if (pretty) try writeColour(cham.dim(), writer, .Open);
    const indent = padding.due + 12;

    var lines = std.mem.split(u8, details, "\n");

    var first: bool = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (first) {
            first = false;
        } else {
            _ = try writer.writeAll("\n");
            _ = try writer.writeByteNTimes(' ', indent);
            _ = try writer.writeAll(". ");
        }

        var itt = std.mem.window(u8, line, STRIDE, STRIDE);
        while (itt.next()) |chunk| {
            _ = try writer.writeAll("\n");
            _ = try writer.writeByteNTimes(' ', indent);
            _ = try writer.writeAll(". ");
            _ = try writer.writeAll(chunk);
        }
    }

    if (pretty) try writeColour(cham.dim(), writer, .Close);
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
        .Done => {
            const c = cham.greenBright();
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

fn printImportanceIndicator(importance: Task.Importance, writer: anytype) !void {
    const indicator: []const u8 = switch (importance) {
        .high => "*",
        .urgent => "!",
        else => " ",
    };
    try writer.print(" {s} ", .{indicator});
}

fn printStatusIndicator(status: Status, writer: anytype) !void {
    const indicator: []const u8 = switch (status) {
        .Done => "✓",
        .NearlyDue => "*",
        .PastDue => "!",
        else => " ",
    };
    try writer.print(" {s} ", .{indicator});
}

fn printDetailIndicator(writer: anytype) !void {
    _ = try writer.writeAll(" [+]");
}
