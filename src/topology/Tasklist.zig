const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const time = @import("time.zig");
const Time = time.Time;
const utils = @import("../utils.zig");
const Descriptor = @import("Root.zig").Descriptor;

const Tasklist = @This();

pub const TASKLIST_DIRECTORY = "tasklists";
pub const TASKLIST_EXTENSION = "json";

pub const Error = error{ DuplicateTask, UnknownImportance };

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

    /// Parse an importance enum from a string
    pub fn parseFromString(str: []const u8) !Importance {
        if (std.ascii.eqlIgnoreCase(str, "low")) return .Low;
        if (std.ascii.eqlIgnoreCase(str, "high")) return .High;
        if (std.ascii.eqlIgnoreCase(str, "urgent")) return .Urgent;
        return Tasklist.Error.UnknownImportance;
    }
};

pub const Task = struct {
    title: []const u8,
    details: ?[]const u8,
    created: Time,
    modified: Time,
    due: ?Time = null,
    done: ?Time = null,
    archived: ?Time = null,
    importance: Importance,
    tags: []Tag,

    /// Get the `Status` of the task relative to some `Time`.
    pub fn getStatus(t: Task, relative: time.Time) Status {
        const now = time.dateFromTime(relative);
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

    fn dueLessThan(_: void, left: Task, right: Task) bool {
        if (left.due) |ld| {
            if (right.due) |rd| return ld < rd;
            return true;
        }
        if (right.due) |_| return false;
        return std.ascii.lessThanIgnoreCase(left.title, right.title);
    }
};

pub const Info = struct {
    tags: []Tag = &.{},
    tasks: []Task = &.{},
};

info: *Info,
descriptor: Descriptor,
allocator: std.mem.Allocator,
index_map: ?[]const usize = null,
mem: ?std.heap.ArenaAllocator = null,

fn getTmpAllocator(self: *Tasklist) std.mem.Allocator {
    if (self.mem == null) {
        self.mem = std.heap.ArenaAllocator.init(self.allocator);
    }
    return self.mem.?.allocator();
}

pub fn deinit(self: *Tasklist) void {
    if (self.mem) |*mem| mem.deinit();
    self.* = undefined;
}

/// Add a new task to the current task list No strings are copied, so it is
/// assumed the contents of the `task` will outlive the `Tasklist`. Asserts no
/// task by the same title exists.
pub fn addNewTask(self: *Tasklist, task: Task) !void {
    if (self.getTask(task.title)) |_|
        return Error.DuplicateTask;

    var list = std.ArrayList(Task).fromOwnedSlice(
        self.getTmpAllocator(),
        self.info.tasks,
    );
    try list.append(task);
    self.info.tasks = try list.toOwnedSlice();

    // update the index map if we have one
    if (self.index_map) |_| {
        _ = try self.makeIndexMap();
    }
}

/// Get task by title. Returns `null` if no task found.
pub fn getTask(self: *Tasklist, title: []const u8) ?Task {
    for (self.info.tasks) |task| {
        if (std.mem.eql(u8, title, task.title)) return task;
    }
    return null;
}

/// Get task by index. Returns `null` if no task found.
pub fn getTaskByIndex(self: *Tasklist, index: usize) !?Task {
    const map = try self.makeIndexMap();
    if (index >= map.len) return null;
    return self.info.tasks[map[index]];
}

/// Make an index map sorted by due date, only relevant for active tasks.
pub fn makeIndexMap(self: *Tasklist) ![]const usize {
    // sort the tasks
    std.sort.insertion(Task, self.info.tasks, {}, Task.dueLessThan);
    const now = time.timeNow();

    var list = std.ArrayList(usize).init(self.getTmpAllocator());
    defer list.deinit();
    for (self.info.tasks, 0..) |t, i| {
        switch (t.getStatus(now)) {
            .NearlyDue, .PastDue, .NoStatus => {
                try list.append(i);
            },
            else => {},
        }
    }

    self.index_map = try list.toOwnedSlice();
    return self.index_map.?;
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Tasklist.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Caller owns memory
pub fn serialize(self: *const Tasklist, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
