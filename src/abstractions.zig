const std = @import("std");
const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const Journal = @import("topology/Journal.zig");
const Directory = @import("topology/Directory.zig");
const Tasklist = @import("topology/Tasklist.zig");
const tags = @import("topology/tags.zig");

const FileSystem = @import("FileSystem.zig");

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

        pub fn getDescriptor(self: @This()) Root.Descriptor {
            return switch (self) {
                inline else => |i| i.descriptor,
            };
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
        self: *const Item,
        comptime attr: []const u8,
        comptime RetType: type,
    ) RetType {
        return switch (self.*) {
            .Note => |i| @field(i.note, attr),
            .Task => |i| @field(i.task, attr),
            .Entry => |i| @field(i.entry, attr),
            .Day => |i| @field(i.day, attr),
            .Collection => unreachable,
        };
    }

    /// Get the creation date
    pub fn getCreated(self: *const Item) time.Time {
        return self.getAttributeOfItem("created", time.Time);
    }

    /// Get the modified date
    pub fn getModified(self: *const Item) time.Time {
        return self.getAttributeOfItem("modified", time.Time);
    }

    /// Get the name of the collection of this item
    pub fn getCollectionName(self: *const Item) []const u8 {
        return switch (self.*) {
            .Note => |n| n.directory.descriptor.name,
            .Task => |tl| tl.tasklist.descriptor.name,
            .Day => |ed| ed.journal.descriptor.name,
            .Entry => |ed| ed.journal.descriptor.name,
            .Collection => |c| c.getDescriptor().name,
        };
    }

    /// Get the collection type of the item
    pub fn getCollectionType(self: *const Item) Root.CollectionType {
        return switch (self.*) {
            .Note => .CollectionDirectory,
            .Task => .CollectionTasklist,
            .Entry, .Day => .CollectionJournal,
            .Collection => |c| switch (c) {
                .directory => .CollectionDirectory,
                .journal => .CollectionJournal,
                .tasklist => .CollectionTasklist,
            },
        };
    }

    /// Get path to the item
    pub fn getPath(self: *const Item) []const u8 {
        switch (self.*) {
            .Note => |i| return i.note.path,
            .Day => |i| return i.day.path,
            .Entry => |i| return i.day.path,
            .Task => |i| return i.tasklist.descriptor.path,
            .Collection => |i| return i.getDescriptor().path,
        }
        return self.getAttributeOfItem("path", []const u8);
    }

    /// Get the name of the item. Returns the formatted timestamp for an entry.
    /// Caller owns the memory.
    pub fn getName(self: *const Item, allocator: std.mem.Allocator) ![]const u8 {
        switch (self.*) {
            // TODO: this is bad
            .Note => |i| return try allocator.dupe(u8, i.note.name),
            .Day => |i| return try allocator.dupe(u8, i.day.name),
            .Entry => |i| return try allocator.dupe(
                u8,
                &(try time.formatDateTimeBuf(i.entry.created.toDate())),
            ),
            .Task => |i| return try allocator.dupe(u8, i.task.outcome),
            .Collection => |i| return try allocator.dupe(
                u8,
                i.getDescriptor().name,
            ),
        }
    }

    /// TODO: replace getName with something more like this
    fn getNameImpl(self: *const Item) []const u8 {
        return switch (self.*) {
            .Note => |i| i.note.name,
            .Day => |i| i.day.name,
            .Task => |i| i.task.outcome,
            .Collection => |i| i.getDescriptor().name,
            .Entry => unreachable,
        };
    }

    /// For sorting by creation date
    pub fn createdDescending(_: void, lhs: Item, rhs: Item) bool {
        return lhs.getCreated().lt(rhs.getCreated());
    }

    /// For sorting by modified date
    pub fn modifiedDescending(_: void, lhs: Item, rhs: Item) bool {
        return lhs.getModified().lt(rhs.getModified());
    }

    /// For sorting alphabetically
    pub fn alphaDescending(_: void, lhs: Item, rhs: Item) bool {
        const lhs_name = lhs.getNameImpl();
        const rhs_name = rhs.getNameImpl();
        return switch (std.ascii.orderIgnoreCase(lhs_name, rhs_name)) {
            .eq, .lt => true,
            .gt => false,
        };
    }

    /// Get the list of tags applied to this item
    pub fn getTags(self: *const Item) []const tags.Tag {
        return self.getAttributeOfItem("tags", []const tags.Tag);
    }

    /// Get a string representing the content of this item
    pub fn getContent(
        self: *Item,
        allocator: std.mem.Allocator,
        fs: FileSystem,
    ) ![]const u8 {
        switch (self.*) {
            .Note => |note| {
                const content = try fs.readFileAlloc(allocator, note.note.path);
                return content;
            },
            .Entry => |entry| {
                return entry.entry.text;
            },
            else => unreachable,
        }
    }

    /// Add tags to an `Item`
    pub fn addTags(self: *Item, new_tags: []const tags.Tag) !void {
        switch (self.*) {
            .Note => |note| {
                try note.directory.addTagsToNote(note.note, new_tags);
            },
            .Entry => |*entry| {
                try entry.journal.addTagsToEntry(entry.day, entry.entry, new_tags);
            },
            .Day => |*day| {
                try day.journal.addTagsToDay(day.day, new_tags);
            },
            .Task => |task| {
                try task.tasklist.addTagsToTask(task.task, new_tags);
            },
            else => unreachable,
        }
    }

    /// Remove tags to an `Item`
    pub fn removeTags(self: *Item, new_tags: []const tags.Tag) !void {
        switch (self.*) {
            .Note => |note| {
                try note.directory.removeTagsFromNote(note.note, new_tags);
            },
            .Entry => |*entry| {
                try entry.journal.removeTagsFromEntry(entry.day, entry.entry, new_tags);
            },
            .Day => |*day| {
                try day.journal.removeTagsFromDay(day.day, new_tags);
            },
            .Task => |task| {
                try task.tasklist.removeTagsFromTask(task.task, new_tags);
            },
            else => unreachable,
        }
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
        return lhs.getTime().time < rhs.getTime().time;
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
        return lhs.getTime().time < rhs.getTime().time;
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
    /// on a given `Date`.
    pub fn eventsOnDay(self: *TaskEventList, date: time.Date) []const TaskEvent {
        const start = for (self.events, 0..) |e, i| {
            if (e.getTime().toDate().date.eql(date.date)) break i;
        } else self.events.len;

        if (start == self.events.len) return &.{};

        const end = for (self.events[start..], start..) |e, i| {
            if (!e.getTime().toDate().date.eql(date.date)) break i;
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
