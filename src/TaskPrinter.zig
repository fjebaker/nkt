const std = @import("std");
const utils = @import("utils.zig");
const Chameleon = @import("chameleon").Chameleon;

const FormatPrinter = @import("FormatPrinter.zig");

const TaskPrinter = @import("TaskPrinter.zig");
const Task = @import("collections/Topology.zig").Task;

const tags = @import("tags.zig");

const Status = Task.Status;

const FormattedEntry = struct {
    due: []const u8,
    pretty_date: ?[]const u8,
    task: Task,
    status: Status,
    index: ?usize,
};

entries: std.ArrayList(FormattedEntry),
mem: std.heap.ArenaAllocator,
now: utils.Date,
pretty: bool,
taginfo: ?[]const tags.TagInfo = null,

pub fn init(alloc: std.mem.Allocator, pretty: bool) TaskPrinter {
    const mem = std.heap.ArenaAllocator.init(alloc);
    const list = std.ArrayList(FormattedEntry).init(alloc);
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

    const indicator = if (overdue) "-" else " ";

    return try std.fmt.allocPrint(
        alloc,
        "{s} {d: >3}d {d:0>2}h {d:0>2}m",
        .{ indicator, days, hours, minutes },
    );
}

pub fn add(self: *TaskPrinter, task: Task, index: ?usize) !void {
    var alloc = self.mem.allocator();
    const due = try self.formatDueDate(alloc, task.due);

    // make date pretty
    const pretty_date: ?[]const u8 =
        if (task.completed) |cmpl|
        try alloc.dupe(
            u8,
            &try utils.formatDateBuf(utils.dateFromMs(cmpl)),
        )
    else if (task.archived) |arch|
        try alloc.dupe(
            u8,
            &try utils.formatDateBuf(utils.dateFromMs(arch)),
        )
    else
        null;

    try self.entries.append(
        .{
            .due = due,
            .status = task.status(self.now),
            .pretty_date = pretty_date,
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

pub fn drain(
    self: *TaskPrinter,
    writer: anytype,
    tag_infos: ?[]const tags.TagInfo,
    details: bool,
) !void {
    var fp = FormatPrinter.init(self.mem.child_allocator, .{ .pretty = self.pretty });
    defer fp.deinit();

    fp.tag_infos = tag_infos;

    const col_widths = self.columnWidth();

    try fp.addText("\n", .{});
    for (self.entries.items) |item| {
        try printTask(&fp, item, col_widths, details);
        try fp.addText("\n", .{});
    }
    try fp.addText("\n", .{});

    try fp.drain(writer);
}

fn printTask(
    fp: *FormatPrinter,
    entry: FormattedEntry,
    padding: Padding,
    details: bool,
) !void {
    comptime var cham = Chameleon.init(.Auto);

    if (entry.index) |index| {
        try fp.addFmtText(" {d: >3}", .{index}, .{ .cham = cham.dim() });
    } else {
        try fp.addText("    ", .{});
    }

    const string = entry.pretty_date orelse entry.due;
    try fp.addNTimes(' ', 1 + padding.due - strLen(string), .{});

    const indicator: []const u8 = switch (entry.status) {
        .Archived => "A",
        .Done => "✓",
        .NearlyDue => "*",
        .PastDue => "!",
        else => " ",
    };
    const due_color = switch (entry.status) {
        .PastDue => cham.bold().redBright(),
        .NearlyDue => cham.yellow(),
        .Done => cham.greenBright(),
        .Archived => cham.dim(),
        else => null,
    };
    try fp.addFmtText("{s} {s}", .{ string, indicator }, .{ .cham = due_color });

    try fp.addText(" | ", .{});

    const importance: []const u8 = switch (entry.task.importance) {
        .high => "*",
        .urgent => "!",
        else => " ",
    };
    const importance_color = switch (entry.task.importance) {
        .high => cham.yellow(),
        .urgent => cham.bold().redBright(),
        else => null,
    };

    try fp.addFmtText(
        "{s} {s}",
        .{ importance, entry.task.title },
        .{ .cham = importance_color },
    );

    const has_details = entry.task.details.len > 0;

    const text_pad: usize = p: {
        if (!details and has_details) {
            try fp.addText(" [+]", .{ .cham = cham.dim() });
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
    const cham = Chameleon.init(.Auto);
    _ = cham;
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
