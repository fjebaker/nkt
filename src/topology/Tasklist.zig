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

pub const Error = error{
    DuplicateTask,
    UnknownImportance,
    NoSuchTask,
};

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
    outcome: []const u8,
    action: ?[]const u8 = null,
    details: ?[]const u8 = null,
    hash: u64,
    created: Time,
    modified: Time,
    due: ?Time = null,
    done: ?Time = null,
    archived: ?Time = null,
    importance: Importance = .Low,
    tags: []Tag = &.{},

    /// Get the `Status` of the task relative to some `Time`.
    pub fn getStatus(t: Task, relative: time.Time) Status {
        const now = time.dateFromTime(relative);
        if (t.archived != null) return .Archived;
        if (t.done) |_| return .Done;
        const due = if (t.due) |dm|
            utils.Date.fromTimestamp(@intCast(dm))
        else
            return .NoStatus;
        if (now.gt(due)) return .PastDue;
        if (due.sub(now).days < 1) return .NearlyDue;
        return .NoStatus;
    }

    /// Return true if the task is completed
    pub fn isDone(t: Task) bool {
        return t.done != null;
    }

    /// Return true if the task is archived
    pub fn isArchived(t: Task) bool {
        return t.archived != null;
    }

    fn dueLessThan(_: void, left: Task, right: Task) bool {
        if (left.due) |ld| {
            if (right.due) |rd| return ld < rd;
            return true;
        }
        if (right.due) |_| return false;
        return std.ascii.lessThanIgnoreCase(left.outcome, right.outcome);
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
/// task by the same outcome exists.
pub fn addNewTask(self: *Tasklist, task: Task) !void {
    if (self.getTaskByHash(task.hash)) |_|
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

/// Get task by outcome. Returns `null` if no task found. If there are multiple matches, will return an `AmbiguousSelection` error.
pub fn getTask(self: *Tasklist, outcome: []const u8) !?Task {
    var selected: ?Task = null;
    for (self.info.tasks) |task| {
        if (std.mem.eql(u8, outcome, task.outcome)) {
            if (selected != null) return error.AmbiguousSelection;
            selected = task;
        }
    }
    return selected;
}

/// Get task by hash. Returns `null` if no task found.
pub fn getTaskByHash(self: *Tasklist, h: u64) ?Task {
    for (self.info.tasks) |task| {
        if (task.hash == h) return task;
    }
    return null;
}

/// Get task by mini hash. Returns `null` if no task found or
/// `error.AmbiguousSelection` if multiple tasks matched.
pub fn getTaskByMiniHash(self: *Tasklist, h: u64) !?Task {
    const shift: u6 = @intCast(@divFloor(@clz(h), 4) * 4);

    var selected: ?Task = null;
    for (self.info.tasks) |task| {
        if (task.hash >> shift == h) {
            if (selected != null) return error.AmbiguousSelection;
            selected = task;
        }
    }
    return selected;
}

test "get by mini hash" {
    var tasks = [_]Task{
        .{
            .outcome = "test outcome",
            .hash = 0xabc123abc1231111,
            .created = 0,
            .modified = 0,
        },
        .{
            .outcome = "test outcome",
            .hash = 0xabd123abc1231111,
            .created = 0,
            .modified = 0,
        },
        .{
            .outcome = "test outcome",
            .hash = 0x7416f4391c40056a,
            .created = 0,
            .modified = 0,
        },
    };
    var info: Info = .{
        .tags = &.{},
        .tasks = &tasks,
    };
    var tl: Tasklist = .{
        .allocator = std.testing.allocator,
        .descriptor = .{
            .name = "test_list",
            .path = "test_list",
            .created = 0,
            .modified = 0,
        },
        .info = &info,
    };

    try std.testing.expectEqualDeep(
        tasks[0],
        tl.getTaskByHash(0xabc123abc1231111).?,
    );
    try std.testing.expectEqualDeep(
        tasks[0],
        (try tl.getTaskByMiniHash(0xabc12)).?,
    );
    try std.testing.expectEqualDeep(
        tasks[2],
        (try tl.getTaskByMiniHash(0x7416f)).?,
    );
}

/// Remove a task from the tasklist.
pub fn removeTask(self: *Tasklist, task: Task) !void {
    var list = std.ArrayList(Task).fromOwnedSlice(
        self.getTmpAllocator(),
        self.info.tasks,
    );

    const index = b: {
        for (list.items, 0..) |t, i| {
            if (t.hash == task.hash) {
                break :b i;
            }
        }
        return Error.NoSuchTask;
    };

    _ = list.orderedRemove(index);
    self.info.tasks = try list.toOwnedSlice();
}

/// Get task by index. Returns `null` if no task found.
pub fn getTaskByIndex(self: *Tasklist, index: usize) !?Task {
    const map = try self.makeIndexMap();
    if (index >= map.len) return null;
    return self.info.tasks[map[index]];
}

/// Make an index map sorted by due date, only relevant for active tasks. The
/// `index_map[i]` corresponds to the `t{i}` task, and returns the index of the
/// task in the `info.tasks` slice.
pub fn makeIndexMap(self: *Tasklist) ![]const usize {
    self.sortTasks();
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

/// Information that is used to compute the hash of the task
pub const HashInfo = struct {
    outcome: []const u8,
    action: ?[]const u8 = null,
};

/// Create a hash for a task to act as a unique identifier
pub fn hash(info: HashInfo) u64 {
    return utils.hash(HashInfo, info);
}

/// Sorts the tasks in canonical order, that is, by due date then
/// alphabetically in reverse order (soonest due last).
pub fn sortTasks(self: *Tasklist) void {
    std.sort.insertion(Task, self.info.tasks, {}, sortCanonical);
    std.mem.reverse(Task, self.info.tasks);
}

fn sortDue(_: void, lhs: Task, rhs: Task) bool {
    const lhs_due = lhs.due;
    const rhs_due = rhs.due;
    if (lhs_due == null and rhs_due == null) return true;
    if (lhs_due == null) return false;
    if (rhs_due == null) return true;
    return lhs_due.? < rhs_due.?;
}

fn sortCanonical(_: void, lhs: Task, rhs: Task) bool {
    const both_same =
        (lhs.due == null and rhs.due == null) or
        (lhs.due != null and rhs.due != null);

    if (both_same and lhs.due == rhs.due) {
        // if they are both due at the same time, we sort lexographically
        return !std.ascii.lessThanIgnoreCase(lhs.outcome, rhs.outcome);
    }

    const due = sortDue({}, lhs, rhs);
    return due;
}
