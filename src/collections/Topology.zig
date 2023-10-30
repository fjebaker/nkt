const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const DATA_STORE_FILENAME = "topology.json";
const TOPOLOGY_SCHEMA_VERSION = "0.1.0";

pub const Tag = struct {
    name: []const u8,
    added: []const u8,
};

pub const InfoScheme = struct {
    created: u64,
    modified: u64,
    name: []const u8,
    path: []const u8,
    tags: []Tag,

    pub fn sortCreated(_: void, lhs: InfoScheme, rhs: InfoScheme) bool {
        return lhs.created < rhs.created;
    }

    pub fn sortModified(_: void, lhs: InfoScheme, rhs: InfoScheme) bool {
        return lhs.modified < rhs.modified;
    }
};

fn ChildMixin(comptime S: type) type {
    const C = inline for (@typeInfo(S).Struct.fields) |f| {
        if (std.mem.eql(u8, f.name, "children")) break f.type;
    } else @compileError("missing field 'children'");
    return struct {
        pub const Info = InfoScheme;
        pub fn init(info: *Info, children: C) S {
            return .{ .info = info, .children = children };
        }

        pub fn sortCreated(_: void, lhs: S, rhs: S) bool {
            return Info.sortCreated({}, lhs.info.*, rhs.info.*);
        }

        pub fn sortModified(_: void, lhs: S, rhs: S) bool {
            return Info.sortModified({}, lhs.info.*, rhs.info.*);
        }

        pub fn getName(self: S) []const u8 {
            return self.info.name;
        }

        pub fn getPath(self: S) []const u8 {
            return self.info.path;
        }

        fn time(
            self: S,
            comptime field: []const u8,
            comptime cmp: enum { Min, Max },
        ) u64 {
            const children = self.children.?;
            std.debug.assert(children.len > 0);

            var val: u64 = @field(children[0], field);
            for (children[1..]) |item| {
                const t = @field(item, field);
                val = switch (cmp) {
                    .Min => @min(val, t),
                    .Max => @max(val, t),
                };
            }

            return val;
        }

        pub fn timeCreated(self: S) u64 {
            return self.time("created", .Min);
        }

        pub fn lastModified(self: S) u64 {
            if (self.children.?.len == 0) return utils.now();
            return self.time("modified", .Max);
        }
    };
}

pub const Description = struct {
    name: []const u8,
    path: []const u8,
    infos: []InfoScheme,
    tags: []Tag,

    pub fn new(alloc: std.mem.Allocator, root: []const u8, name: []const u8) !Description {
        const path = try std.mem.concat(alloc, u8, &.{ root, name });
        errdefer alloc.free(path);
        const infos = try alloc.alloc(InfoScheme, 0);
        errdefer alloc.free(infos);
        const tags = try alloc.alloc(Tag, 0);
        errdefer alloc.free(tags);

        return .{
            .name = try alloc.dupe(u8, name),
            .path = path,
            .infos = infos,
            .tags = tags,
        };
    }
};

// directories
pub const Directory = Description;

// journal
const EntryScheme = struct { items: []Entry };
pub fn parseEntries(alloc: std.mem.Allocator, string: []const u8) ![]Entry {
    var content = try std.json.parseFromSliceLeaky(
        EntryScheme,
        alloc,
        string,
        .{ .allocate = .alloc_always },
    );
    return content.items;
}
pub fn stringifyEntries(alloc: std.mem.Allocator, items: []Entry) ![]const u8 {
    return try std.json.stringifyAlloc(
        alloc,
        EntryScheme{ .items = items },
        .{ .whitespace = .indent_4 },
    );
}

pub const Entry = struct {
    created: u64,
    modified: u64,
    item: []const u8,
    tags: []Tag,

    pub fn sortCreated(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.created < rhs.created;
    }

    pub fn sortModified(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.modified < rhs.modified;
    }
};
pub const Journal = Description;

pub const Task = struct {
    pub const Importance = enum { low, high, urgent };
    title: []const u8,
    details: []const u8,
    created: u64,
    modified: u64,
    completed: ?u64,
    due: ?u64,
    importance: Importance,
    tags: []Tag,
    done: bool,

    pub fn sortCreated(_: void, lhs: Task, rhs: Task) bool {
        return lhs.created < rhs.created;
    }

    pub fn sortModified(_: void, lhs: Task, rhs: Task) bool {
        return lhs.modified < rhs.modified;
    }

    pub fn sortDue(_: void, lhs: Task, rhs: Task) bool {
        if (lhs.due == null and rhs.due == null) return true;
        if (lhs.due == null) return false;
        if (rhs.due == null) return true;
        return lhs.due.? < rhs.due.?;
    }

    pub fn sortImportance(_: void, lhs: Task, rhs: Task) bool {
        if (lhs.importance == .low and rhs.importance == .high)
            return true;
        return false;
    }
};

const TaskScheme = struct { items: []Task };
pub fn parseTasks(alloc: std.mem.Allocator, string: []const u8) ![]Task {
    var content = try std.json.parseFromSliceLeaky(
        TaskScheme,
        alloc,
        string,
        .{ .allocate = .alloc_always },
    );
    return content.items;
}
pub fn stringifyTasks(alloc: std.mem.Allocator, items: []Task) ![]const u8 {
    return try std.json.stringifyAlloc(
        alloc,
        TaskScheme{ .items = items },
        .{ .whitespace = .indent_4 },
    );
}

pub const TasklistInfo = InfoScheme;
pub const TaskList = struct {
    info: *InfoScheme,
    children: ?[]Task,
    pub usingnamespace ChildMixin(@This());

    pub fn parseContent(alloc: std.mem.Allocator, string: []const u8) ![]Task {
        var content = try std.json.parseFromSliceLeaky(
            TaskScheme,
            alloc,
            string,
            .{ .allocate = .alloc_always },
        );
        return content.items;
    }

    pub fn stringifyContent(alloc: std.mem.Allocator, items: []Task) ![]const u8 {
        return try std.json.stringifyAlloc(
            alloc,
            TaskScheme{ .items = items },
            .{ .whitespace = .indent_4 },
        );
    }

    pub fn contentTemplate(alloc: std.mem.Allocator, info: InfoScheme) []const u8 {
        _ = alloc;
        _ = info;
        return "{\"items\":[]}";
    }
};

const TopologySchema = struct {
    _schema_version: []const u8,
    editor: [][]const u8,
    pager: [][]const u8,
    tasklists: []TasklistInfo,
    directories: []Directory,
    journals: []Journal,
};

directories: []Directory,
journals: []Journal,
tasklists: []TasklistInfo,
editor: [][]const u8,
pager: [][]const u8,
mem: std.heap.ArenaAllocator,

pub fn initNew(alloc: std.mem.Allocator) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();

    var directories = try temp_alloc.alloc(Directory, 0);
    var journals = try temp_alloc.alloc(Journal, 0);
    var tasklists = try temp_alloc.alloc(TasklistInfo, 0);
    var editor = try temp_alloc.dupe([]const u8, &.{"vim"});
    var pager = try temp_alloc.dupe([]const u8, &.{"less"});

    return .{
        .directories = directories,
        .journals = journals,
        .tasklists = tasklists,
        .editor = editor,
        .pager = pager,
        .mem = mem,
    };
}

pub fn init(alloc: std.mem.Allocator, data: []const u8) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();
    var schema = try std.json.parseFromSliceLeaky(
        TopologySchema,
        temp_alloc,
        data,
        .{ .allocate = .alloc_always },
    );

    return .{
        .directories = schema.directories,
        .journals = schema.journals,
        .tasklists = schema.tasklists,
        .editor = schema.editor,
        .pager = schema.pager,
        .mem = mem,
    };
}

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}

/// Caller owns the memory.
pub fn toString(self: *Self, alloc: std.mem.Allocator) ![]const u8 {
    const schema: TopologySchema = .{
        ._schema_version = TOPOLOGY_SCHEMA_VERSION,
        .directories = self.directories,
        .journals = self.journals,
        .tasklists = self.tasklists,
        .editor = self.editor,
        .pager = self.pager,
    };
    return std.json.stringifyAlloc(alloc, schema, .{ .whitespace = .indent_4 });
}
