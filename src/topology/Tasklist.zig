const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const time = @import("time.zig");
const Time = time.Time;
const utils = @import("../utils.zig");
const Descriptor = @import("Root.zig").Descriptor;

const Selector = @import("../selections.zig").Selector;
const SelectionConfig = @import("../selections.zig").SelectionConfig;

const Tasklist = @This();

pub const TASKLIST_DIRECTORY = "tasklists";
pub const TASKLIST_EXTENSION = "json";

pub const MINI_HASH_LEN = 5;
pub const MINI_HASH_MAX_VALUE = std.math.powi(
    u64,
    16,
    MINI_HASH_LEN,
) catch unreachable;

pub const Error = error{
    DuplicateTask,
    UnknownImportance,
    NoSuchTask,
    AlreadyDone,
    AlreadyArchived,
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
        const now = relative.toDate();
        if (t.archived != null) return .Archived;
        if (t.done) |_| return .Done;
        const due = if (t.due) |dm|
            dm.toDate()
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
index_map: ?[]?usize = null,

/// Add a new task to the current task list No strings are copied, so it is
/// assumed the contents of the `task` will outlive the `Tasklist`. Asserts no
/// task by the same outcome exists.
pub fn addNewTask(self: *Tasklist, task: Task) !void {
    if (self.getTaskByHash(task.hash)) |_|
        return Error.DuplicateTask;

    var list = std.ArrayList(Task).fromOwnedSlice(
        self.allocator,
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
    const ptr = self.getTaskByHashPtr(h) orelse return null;
    return ptr.*;
}

/// Get a pointer to a task by hash. Returns `null` if no task found.
pub fn getTaskByHashPtr(self: *const Tasklist, h: u64) ?*Task {
    for (self.info.tasks) |*task| {
        if (task.hash == h) return task;
    }
    return null;
}

/// Get task by mini hash. Returns `null` if no task found or
/// `error.AmbiguousSelection` if multiple tasks matched.
/// Mini hashes are defined as the last MINI_HASH_LEN numbers in the hex
/// expression.
pub fn getTaskByMiniHash(self: *Tasklist, h: u64) !?Task {
    const shift = (16 - MINI_HASH_LEN) * 4;

    var selected: ?Task = null;
    for (self.info.tasks) |task| {
        if (task.hash >> shift == h) {
            if (selected != null) return error.AmbiguousSelection;
            selected = task;
        }
    }
    return selected;
}

/// Rename and move files associated with the Note at `old_name` to `new_name`.
pub fn rename(
    self: *Tasklist,
    old: Task,
    new_outcome: []const u8,
) !Task {
    var ptr = self.getTaskByHashPtr(old.hash) orelse
        return Error.NoSuchTask;
    ptr.outcome = new_outcome;
    // recompute hash
    ptr.hash = hash(.{ .outcome = new_outcome, .action = old.action });
    ptr.modified = time.Time.now();
    return ptr.*;
}

test "get by mini hash" {
    var tasks = [_]Task{
        .{
            .outcome = "test outcome",
            .hash = 0xabc123abc1231111,
            .created = .{ .time = 0 },
            .modified = .{ .time = 0 },
        },
        .{
            .outcome = "test outcome",
            .hash = 0xabd123abc1231111,
            .created = .{ .time = 0 },
            .modified = .{ .time = 0 },
        },
        .{
            .outcome = "test outcome",
            .hash = 0x7416f4391c40056a,
            .created = .{ .time = 0 },
            .modified = .{ .time = 0 },
        },
        .{
            .outcome = "leading zero",
            .hash = 0x0016f4391c40056a,
            .created = .{ .time = 0 },
            .modified = .{ .time = 0 },
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
            .created = .{ .time = 0 },
            .modified = .{ .time = 0 },
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
    try std.testing.expectEqualDeep(
        tasks[3],
        (try tl.getTaskByMiniHash(0x0016f)).?,
    );
}

/// Remove a task from the tasklist.
pub fn removeTask(self: *Tasklist, task: Task) !void {
    var list = std.ArrayList(Task).fromOwnedSlice(
        self.allocator,
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
    // remake the index map to reflect updates
    _ = try self.makeIndexMap();
}

/// Get task by index. Returns `null` if no task found.
pub fn getTaskByIndex(self: *Tasklist, index: usize) !?Task {
    const map = try self.makeIndexMap();
    const i = std.mem.indexOfScalar(?usize, map, index) orelse
        return null;
    return self.info.tasks[i];
}

/// Make an index map sorted by due date, only relevant for active tasks. The
/// `index_map[i] == j` is the `t{j}` task, where `i` is the index mapping to
/// the tasklist.
pub fn makeIndexMap(self: *Tasklist) ![]const ?usize {
    self.sortTasks(.canonical);
    std.mem.reverse(Task, self.info.tasks);

    var alloc = self.allocator;
    const index_map = b: {
        if (self.index_map) |im| {
            if (im.len == self.info.tasks.len) {
                break :b self.index_map.?;
            }
            alloc.free(im);
        }
        break :b try alloc.alloc(?usize, self.info.tasks.len);
    };

    var index: usize = 0;
    for (self.info.tasks, index_map) |t, *i| {
        if (t.archived == null and t.done == null) {
            i.* = index;
            index += 1;
        } else {
            i.* = null;
        }
    }

    // TODO: this can definitely be cleaned up to avoid 3 reversals
    std.mem.reverse(Task, self.info.tasks);
    std.mem.reverse(?usize, index_map);
    self.index_map = index_map;
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

/// Add tags to a given `Task`
pub fn addTagsToTask(self: *const Tasklist, task: Task, new_tags: []const tags.Tag) !void {
    const ptr = self.getTaskByHashPtr(task.hash).?;
    ptr.tags = try tags.setUnion(self.allocator, task.tags, new_tags);
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

/// Options for controlling how the tasks in the tasklist are sorted
pub const SortingOptions = struct {
    how: enum { canonical, alphabetically, modified, created } = .canonical,
};

/// Sorts the tasks in canonical order, that is, by due date then
/// alphabetically in reverse order (soonest due last).
pub fn sortTasks(self: *Tasklist, opts: SortingOptions) void {
    std.sort.insertion(Task, self.info.tasks, opts, taskSorter);
    std.mem.reverse(Task, self.info.tasks);
}

fn sortDue(_: void, lhs: Task, rhs: Task) bool {
    const lhs_due = lhs.due;
    const rhs_due = rhs.due;
    if (lhs_due == null and rhs_due == null) return true;
    if (lhs_due == null) return false;
    if (rhs_due == null) return true;
    return lhs_due.?.time < rhs_due.?.time;
}

/// Used to compare two tasks together for the purposes of sorting
pub fn taskSorter(opts: SortingOptions, lhs: Task, rhs: Task) bool {
    const both_same =
        (lhs.due == null and rhs.due == null) or
        ((lhs.due != null and rhs.due != null) and (lhs.due.?.eql(rhs.due.?)));

    if (both_same) {
        switch (opts.how) {
            .canonical, .alphabetically => {
                return !std.ascii.lessThanIgnoreCase(lhs.outcome, rhs.outcome);
            },
            .created => {
                return lhs.created.lt(rhs.created);
            },
            .modified => {
                return lhs.modified.lt(rhs.modified);
            },
        }
    }

    const due = sortDue({}, lhs, rhs);
    return due;
}

/// Used to retrieve specific items from a journal
pub fn select(self: *Tasklist, selector: Selector, config: SelectionConfig) !Task {
    try config.noModifiers();
    const maybe_task: ?Tasklist.Task = switch (selector) {
        .ByName => |n| try self.getTask(n),
        .ByIndex, .ByQualifiedIndex => try self.getTaskByIndex(
            selector.getIndex(),
        ),
        .ByDate => return error.InvalidSelection,
        .ByHash => |h| b: {
            if (h <= Tasklist.MINI_HASH_MAX_VALUE) {
                break :b try self.getTaskByMiniHash(h);
            } else {
                break :b self.getTaskByHash(h);
            }
        },
    };

    return maybe_task orelse error.NoSuchItem;
}
