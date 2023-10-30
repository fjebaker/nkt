const std = @import("std");

const utils = @import("../utils.zig");
const content_map = @import("content_map.zig");

const FileSystem = @import("../FileSystem.zig");
const Topology = @import("Topology.zig");

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Directory = struct {
    pub const ContentMap = content_map.ContentMap([]const u8);
    pub const DEFAULT_FILE_EXTENSION = ".md";
    pub const Note = Topology.Note;

    mem: std.heap.ArenaAllocator,
    fs: *FileSystem,
    description: *Topology.Description,
    content: ContentMap,
    modified: bool,

    pub fn readContent(d: *Directory, note: *Note) !void {
        var alloc = d.content.allocator();
        const content = try d.fs.readFileAlloc(alloc, note.info.path);
        try d.content.putMove(note.info.name, content);
    }

    pub fn deinit(d: *Directory) void {
        d.mem.deinit();
        d.content.deinit();
        d.* = undefined;
    }
};

const Journal = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const ContentMap = content_map.ContentMap([]Entry);
    pub const Entry = Topology.Entry;
    pub const Day = Topology.Day;

    mem: std.heap.ArenaAllocator,
    fs: *FileSystem,
    description: *Topology.Description,
    content: ContentMap,
    index: IndexContainer,
    modified: bool,

    pub fn readEntries(j: *Journal, day: *Day) ![]Entry {
        var alloc = j.content.allocator();
        const string = try j.fs.readFileAlloc(alloc, day.info.path);
        var entries = try Topology.parseEntries(alloc, string);
        try j.content.putMove(day.info.name, entries);
    }

    pub fn deinit(j: *Journal) void {
        j.mem.deinit();
        j.content.deinit();
        j.index.deinit();
        j.* = undefined;
    }
};

const Tasklist = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const Task = Topology.Task;

    mem: std.heap.ArenaAllocator,
    fs: *FileSystem,
    info: *Topology.TaskListInfo,
    tasks: ?[]Task,
    modified: bool,

    pub fn readTasks(self: *Tasklist) ![]Task {
        return self.tasks orelse {
            var alloc = self.mem.allocator();
            const string = try self.fs.readFileAlloc(
                alloc,
                self.info.path,
            );
            self.tasks = try Topology.parseTasks(alloc, string);
            return self.tasks.?;
        };
    }

    pub fn deinit(t: *Tasklist) void {
        t.mem.deinit();
        t.* = undefined;
    }
};

pub const Item = union(enum) {
    Note: struct {
        dir: *Directory,
        note: Directory.Note,
        pub fn read(self: *@This()) ![]const u8 {
            if (self.note.children) |content| return content;
            try self.dir.getContent(&self.note);
            return self.note.children.?;
        }
    },

    Day: struct {
        journal: *Journal,
        day: Journal.Day,
    },

    Task: struct {
        tasklist: *Tasklist,
        task: Tasklist.Task,
    },

    pub fn getCreated(item: *const Item) u64 {
        return switch (item.*) {
            .Note => |n| n.note.info.created,
            .Day => |d| d.day.info.created,
            .Task => |t| t.task.created,
        };
    }

    pub fn getModified(item: *const Item) u64 {
        return switch (item.*) {
            .Note => |n| n.note.info.modified,
            .Day => |d| d.day.info.modified,
            .Task => |t| t.task.modified,
        };
    }
};

const eql = std.mem.eql;
const ArrayList = std.ArrayList;

pub const Types = enum { Directory, Journal, Tasklist };

pub const Collection = union(Types) {
    Directory: Directory,
    Journal: Journal,
    Tasklist: Tasklist,

    inline fn getIndexByProperty(
        c: *Collection,
        comptime property: []const u8,
        value: []const u8,
    ) ?usize {
        switch (c.*) {
            .Tasklist => |*s| {
                const tasks = s.tasks orelse return null;
                for (0.., tasks) |i, task| {
                    if (eql(u8, @field(task, property), value))
                        return i;
                }
                return null;
            },
            inline else => |*s| {
                for (0.., s.description.infos) |i, info| {
                    if (eql(u8, @field(info, property), value))
                        return i;
                }
                return null;
            },
        }
    }

    pub fn getByIndex(c: *Collection, index: usize) ?Item {
        switch (c.*) {
            .Tasklist => |*s| {
                var tasks = s.tasks orelse return null;
                if (index >= tasks.len)
                    return null;
                var task = &tasks[index];
                return .{ .Task = .{ .tasklist = s, .task = task } };
            },
            .Directory => |*s| {
                if (index >= s.description.infos)
                    return null;
                const note = &s.description.infos;
                return .{ .Note = .{ .dir = s, .note = note } };
            },
            .Journal => |*s| {
                if (index >= s.description.infos)
                    return null;
                const day = &s.description.infos;
                return .{ .Day = .{ .journal = s, .day = day } };
            },
        }
    }

    inline fn getSize(c: *const Collection) usize {
        switch (c.*) {
            .Tasklist => |s| {
                const tasks = s.tasks orelse return 0;
                return tasks.len;
            },
            inline else => |s| return s.description.infos.len,
        }
    }

    pub fn get(c: *Collection, name: []const u8) ?Item {
        const index = c.getIndexByProperty("name", name);
        return c.getByIndex(index);
    }

    pub fn getByPath(c: *Collection, path: []const u8) ?Item {
        const index = c.getIndexByProperty("path", path);
        return c.getByIndex(index);
    }
};
