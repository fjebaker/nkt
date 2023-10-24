const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const DATA_STORE_FILENAME = "topology.json";
const TOPOLOGY_SCHEMA_VERSION = "0.1.0";

pub const Tag = struct {
    name: []const u8,
    added: []const u8,
};

const InfoScheme = struct {
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

pub fn ChildScheme(comptime S: type) type {
    const C = inline for (@typeInfo(S).Struct.fields) |f| {
        if (std.mem.eql(u8, f.name, "children")) break f.type;
    } else @compileError("missing field 'children'");
    const TPtr = @typeInfo(@typeInfo(C).Optional.child).Pointer;
    const T = TPtr.child;
    return struct {
        pub const Info = InfoScheme;
        pub const Item = T;
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
            return self.time("modified", .Max);
        }
    };
}

pub const CollectionScheme = struct {
    name: []const u8,
    path: []const u8,
    infos: []InfoScheme,
    tags: []Tag,
};

// directories
pub const Directory = CollectionScheme;
pub const Note = struct {
    info: *InfoScheme,
    children: ?[]const u8,
    pub usingnamespace ChildScheme(@This());

    pub fn parseContent(alloc: std.mem.Allocator, string: []const u8) ![]const u8 {
        _ = alloc;
        return string;
    }

    pub fn stringifyContent(alloc: std.mem.Allocator, items: []const u8) ![]const u8 {
        _ = alloc;
        return items;
    }
};

// journal
const EntryItem = struct {
    created: u64,
    modified: u64,
    item: []const u8,
    tags: []Tag,

    pub fn sortCreated(_: void, lhs: EntryItem, rhs: EntryItem) bool {
        return lhs.created < rhs.created;
    }

    pub fn sortModified(_: void, lhs: EntryItem, rhs: EntryItem) bool {
        return lhs.modified < rhs.modified;
    }
};
pub const Journal = CollectionScheme;
pub const Entry = struct {
    info: *InfoScheme,
    children: ?[]EntryItem,
    pub usingnamespace ChildScheme(@This());

    const ItemScheme = struct { items: []Entry.Item };

    pub fn parseContent(alloc: std.mem.Allocator, string: []const u8) ![]Entry.Item {
        var content = try std.json.parseFromSliceLeaky(
            ItemScheme,
            alloc,
            string,
            .{ .allocate = .alloc_always },
        );
        return content.items;
    }

    pub fn stringifyContent(alloc: std.mem.Allocator, items: []Entry.Item) ![]const u8 {
        return try std.json.stringifyAlloc(
            alloc,
            ItemScheme{ .items = items },
            .{ .whitespace = .indent_4 },
        );
    }
};

pub const TaskList = struct {
    pub const Task = struct {
        name: []const u8,
        text: []const u8,
        created: u64,
        modified: u64,
        due: u64,
        tags: []Tag,
    };
    name: []const u8,
    path: []const u8,
    created: u64,
    tasks: []Task,
    tags: []Tag,
};

const TopologySchema = struct {
    _schema_version: []const u8,
    editor: []const u8,
    pager: []const u8,
    tasklists: []TaskList,
    directories: []Directory,
    journals: []Journal,
};

directories: []Directory,
journals: []Journal,
tasklists: []TaskList,
editor: []const u8,
pager: []const u8,
mem: std.heap.ArenaAllocator,

pub fn initNew(alloc: std.mem.Allocator) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();

    var directories = try temp_alloc.alloc(Directory, 0);
    var journals = try temp_alloc.alloc(Journal, 0);
    var tasklists = try temp_alloc.alloc(TaskList, 0);
    var editor = try temp_alloc.dupe(u8, "vim");
    var pager = try temp_alloc.dupe(u8, "less");

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
