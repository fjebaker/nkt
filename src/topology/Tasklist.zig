const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const Time = @import("time.zig").Time;
const utils = @import("../utils.zig");

const Tasklist = @This();

pub const TOPOLOGY_FILENAME = "topology.json";

pub const Status = enum {
    PastDue,
    NearlyDue,
    NoStatus,
    Done,
    Archived,
};
pub const Importance = enum {
    Low,
    High,
    Urgent,
};

pub const Task = struct {
    title: []const u8,
    details: []const u8,
    created: Time,
    modified: Time,
    due: ?Time = null,
    done: ?Time = null,
    archived: ?Time = null,
    importance: Importance,
    tags: []Tag,

    pub fn getStatus(t: Task, now: utils.Date) Status {
        if (t.done) |_| return .Done;
        if (t.archived != null) return .Archived;
        const due = if (t.due) |dm|
            utils.Date.fromTimestamp(@intCast(dm))
        else
            return .NoStatus;
        if (now.gt(due)) return .PastDue;
        if (due.sub(now).days < 1) return .NearlyDue;
        return .NoStatus;
    }
};

pub const Info = struct {
    tags: []Tag = &.{},
    tasks: []Task = &.{},
};

info: *Info,
allocator: std.mem.Allocator,

pub fn deinit(self: *Tasklist) void {
    self.allocator.free(self.info.tags);
    self.allocator.free(self.info.tasks);
    self.* = undefined;
}

/// Add a new task to the current task list No strings are copied, so it is
/// assumed the contents of the `task` will outlive the `Tasklist`.
pub fn addNewTask(self: *Tasklist, task: Task) !void {
    var list = std.ArrayList(Task).fromOwnedSlice(
        self.allocator,
        self.info.tasks,
    );
    try list.append(task);
    self.info.tasks = try list.toOwnedSlice();
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Tasklist.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Caller owns memory
pub fn serialize(self: *Tasklist, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
