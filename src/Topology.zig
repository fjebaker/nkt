const std = @import("std");
const utils = @import("utils.zig");

const Self = @This();

pub const DATA_STORE_FILENAME = "topology.json";

pub const Note = struct {
    pub const Info = struct {
        created: u64,
        modified: u64,
        name: []const u8,
        path: []const u8,

        pub fn sortCreated(_: void, lhs: Info, rhs: Info) bool {
            return lhs.created < rhs.created;
        }

        pub fn sortModified(_: void, lhs: Info, rhs: Info) bool {
            return lhs.modified < rhs.modified;
        }
    };

    info: *Info,
    content: ?[]const u8,

    pub fn sortCreated(_: void, lhs: Note, rhs: Note) bool {
        return Info.sortCreated({}, lhs.info.*, rhs.info.*);
    }

    pub fn sortModified(_: void, lhs: Note, rhs: Note) bool {
        return Info.sortModified({}, lhs.info.*, rhs.info.*);
    }
};

pub const Journal = struct {
    pub const Entry = struct {
        created: u64,
        modified: u64,
        entry: []const u8,

        pub fn sortCreated(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.created < rhs.created;
        }

        pub fn sortModified(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.modified < rhs.modified;
        }
    };
    name: []const u8,
    entries: []Entry,
};

pub const Directory = struct {
    name: []const u8,
    path: []const u8,
    infos: []Note.Info,
};

const TopologySchema = struct {
    directories: []Directory,
    journals: []Journal,
    editor: []const u8,
    pager: []const u8,
};

directories: []Directory,
journals: []Journal,
editor: []const u8,
pager: []const u8,
mem: std.heap.ArenaAllocator,

pub fn initNew(alloc: std.mem.Allocator) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();

    var directories = try temp_alloc.alloc(Directory, 0);
    var journals = try temp_alloc.alloc(Journal, 0);
    var editor = try temp_alloc.dupe(u8, "vim");
    var pager = try temp_alloc.dupe(u8, "less");

    return .{
        .directories = directories,
        .journals = journals,
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
        .directories = self.directories,
        .journals = self.journals,
        .editor = self.editor,
        .pager = self.pager,
    };
    return std.json.stringifyAlloc(alloc, schema, .{ .whitespace = .indent_4 });
}
