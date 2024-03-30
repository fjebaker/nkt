const std = @import("std");
const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const Journal = @import("topology/Journal.zig");
const Directory = @import("topology/Directory.zig");
const Tasklist = @import("topology/Tasklist.zig");

/// Structure representing the abstraction of an item along with its parent
/// colleciton.
pub const Item = union(enum) {
    Entry: struct {
        journal: Journal,
        day: Journal.Day,
        entry: Journal.Entry,
    },
    Day: struct {
        journal: Journal,
        day: Journal.Day,
    },
    Note: struct {
        directory: Directory,
        note: Directory.Note,
    },
    Task: struct {
        tasklist: Tasklist,
        task: Tasklist.Task,
    },
    Collection: union(enum) {
        directory: Directory,
        journal: Journal,
        tasklist: Tasklist,
        // TODO: chains, etc.

        /// Call the relevant destructor irrelevant of active field.
        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                inline else => |*i| i.deinit(),
            }
            self.* = undefined;
        }

        fn eql(i: @This(), j: @This()) bool {
            if (std.meta.activeTag(i) != std.meta.activeTag(j))
                return false;

            switch (i) {
                inline else => |ic| {
                    switch (j) {
                        inline else => |jc| return std.mem.eql(
                            u8,
                            ic.descriptor.path,
                            jc.descriptor.path,
                        ),
                    }
                },
            }
        }
    },

    /// Call the relevant destructor irrelevant of active field.
    pub fn deinit(self: *Item) void {
        switch (self.*) {
            .Entry => |*i| i.journal.deinit(),
            .Day => |*i| i.journal.deinit(),
            .Note => |*i| i.directory.deinit(),
            .Task => |*i| i.tasklist.deinit(),
            .Collection => |*i| i.deinit(),
        }
        self.* = undefined;
    }

    /// Are the items equal?
    pub fn eql(i: Item, j: Item) bool {
        if (std.meta.activeTag(i) != std.meta.activeTag(j))
            return false;
        switch (i) {
            .Entry => |is| {
                const js = j.Entry;
                return std.mem.eql(u8, js.entry.text, is.entry.text);
            },
            .Day => |id| {
                const jd = j.Day;
                return std.mem.eql(u8, jd.day.name, id.day.name) and
                    std.mem.eql(
                    u8,
                    id.journal.descriptor.name,
                    id.journal.descriptor.name,
                );
            },
            .Note => |in| {
                const jn = j.Note;
                return std.mem.eql(u8, in.note.name, jn.note.name) and
                    std.mem.eql(
                    u8,
                    in.directory.descriptor.name,
                    jn.directory.descriptor.name,
                );
            },
            .Task => |it| {
                const jt = j.Task;
                return std.mem.eql(u8, it.task.outcome, jt.task.outcome) and
                    std.mem.eql(
                    u8,
                    it.tasklist.descriptor.name,
                    jt.tasklist.descriptor.name,
                );
            },
            .Collection => |ic| {
                const jc = j.Collection;
                return ic.eql(jc);
            },
        }
    }

    fn getAttributeOfItem(
        self: *Item,
        comptime attr: []const u8,
        comptime RetType: type,
    ) RetType {
        switch (self.*) {
            .Note => |i| @field(i.note, attr),
            .Task => |i| @field(i.task, attr),
            .Entry => |i| @field(i.entry, attr),
            .Day => |i| @field(i.day, attr),
            .Collection => unreachable,
        }
    }

    fn getCollectionDescriptor(self: *Item) Root.Descriptor {
        switch (self.*) {
            .Note => |i| i.directory.descriptor,
            .Task => |i| i.tasklist.descriptor,
            .Entry => |i| i.journal.descriptor,
            .Day => |i| i.journal.descriptor,
            .Collection => |i| i.descriptor,
        }
    }

    /// Get the creation date
    pub fn getCreated(self: *const Item) time.Time {
        return self.getAttributeOfItem("created", time.Time);
    }

    /// For sorting by creation date
    pub fn createdDescending(_: void, lhs: Item, rhs: Item) bool {
        return lhs.getCreated() < rhs.getCreated();
    }
};

pub const TaskEvent = struct {
    event: enum { Created, Done, Archived },
    task: Tasklist.Task,

    /// Get the time at which the event occured
    pub fn getTime(t: *const TaskEvent) time.Time {
        return switch (t.event) {
            .Created => t.task.created,
            .Done => t.task.done.?,
            .Archived => t.task.archived.?,
        };
    }

    pub fn timeAscending(
        _: void,
        lhs: TaskEvent,
        rhs: TaskEvent,
    ) bool {
        return lhs.getTime() < rhs.getTime();
    }
};

pub const EntryOrTaskEvent = union(enum) {
    entry: Journal.Entry,
    task_event: TaskEvent,

    pub fn getTime(self: EntryOrTaskEvent) time.Time {
        return switch (self) {
            .entry => |e| e.created,
            .task_event => |t| t.getTime(),
        };
    }

    pub fn timeAscending(
        _: void,
        lhs: EntryOrTaskEvent,
        rhs: EntryOrTaskEvent,
    ) bool {
        return lhs.getTime() < rhs.getTime();
    }
};

pub fn entryOrTaskEventList(
    allocator: std.mem.Allocator,
    entries: []const Journal.Entry,
    tasks: []const TaskEvent,
) ![]EntryOrTaskEvent {
    var list = try std.ArrayList(EntryOrTaskEvent).initCapacity(
        allocator,
        entries.len + tasks.len,
    );
    defer list.deinit();

    for (entries) |e| {
        list.appendAssumeCapacity(.{ .entry = e });
    }

    for (tasks) |e| {
        list.appendAssumeCapacity(.{ .task_event = e });
    }

    return try list.toOwnedSlice();
}

pub const TaskEventList = struct {
    events: []TaskEvent,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        tasks: []const Tasklist.Task,
    ) !TaskEventList {
        const events = try taskEventList(allocator, tasks);
        // sort them chronologically
        std.sort.insertion(TaskEvent, events, {}, TaskEvent.timeAscending);
        return .{
            .events = events,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskEventList) void {
        self.allocator.free(self.events);
        self.* = undefined;
    }

    /// Returns all events that take place between the start and end of a day
    /// from a given time.
    pub fn eventsOnDay(self: *TaskEventList, date: time.Date) []const TaskEvent {
        const start_time = time.timeFromDate(time.startOfDay(date));
        const end_time = time.timeFromDate(time.endOfDay(date));

        const start = for (self.events, 0..) |e, i| {
            if (e.getTime() >= start_time) break i;
        } else self.events.len;

        if (start == self.events.len) return &.{};

        const end = for (self.events[start..], start..) |e, i| {
            if (e.getTime() >= end_time) break i;
        } else self.events.len;

        return self.events[start..end];
    }

    fn taskEventList(
        allocator: std.mem.Allocator,
        tasks: []const Tasklist.Task,
    ) ![]TaskEvent {
        var list = std.ArrayList(TaskEvent).init(allocator);
        defer list.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        for (tasks) |t| {
            const events = try unpackTaskEvents(arena.allocator(), t);
            for (events) |e| {
                try list.append(e);
            }
        }

        return list.toOwnedSlice();
    }
};

fn unpackTaskEvents(
    allocator: std.mem.Allocator,
    t: Tasklist.Task,
) ![]const TaskEvent {
    var list = std.ArrayList(TaskEvent).init(allocator);
    defer list.deinit();

    try list.append(.{
        .event = .Created,
        .task = t,
    });

    if (t.isArchived()) {
        try list.append(.{
            .event = .Archived,
            .task = t,
        });
    }

    if (t.isDone()) {
        try list.append(.{
            .event = .Done,
            .task = t,
        });
    }

    return list.toOwnedSlice();
}