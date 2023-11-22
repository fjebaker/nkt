const std = @import("std");
const utils = @import("../utils.zig");

const Self = @This();

pub const DATA_STORE_FILENAME = "topology.json";
const TOPOLOGY_SCHEMA_VERSION = "0.1.0";

pub const Tag = struct {
    name: []const u8,
    added: u64,
};

pub const TagInfo = struct {
    name: []const u8,
    created: u64,
    color: []const u8,
};

pub const InfoScheme = struct {
    created: u64,
    modified: u64,
    name: []const u8,
    path: []const u8,
    tags: []Tag,
};

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
    const content = try std.json.parseFromSliceLeaky(
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
};
pub const Journal = Description;

pub const Task = struct {
    pub const Status = enum { PastDue, NearlyDue, NoStatus, Done };
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

    pub fn status(t: Task, now: utils.Date) Status {
        if (t.done) return .Done;
        const due = if (t.due) |dm|
            utils.Date.fromTimestamp(@intCast(dm))
        else
            return .NoStatus;
        if (now.gt(due)) return .PastDue;
        if (due.sub(now).days < 1) return .NearlyDue;
        return .NoStatus;
    }
};

const TaskScheme = struct { items: []Task };
pub fn parseTasks(alloc: std.mem.Allocator, string: []const u8) ![]Task {
    const content = try std.json.parseFromSliceLeaky(
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

pub const DEFAULT_CHAIN_FILENAME = "chains.json";
pub const Chain = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    details: ?[]const u8 = null,
    active: bool,
    created: u64,
    tags: []Tag,
    completed: []u64,
};

const ChainScheme = struct { chains: []Chain };
pub fn parseChains(alloc: std.mem.Allocator, string: []const u8) ![]Chain {
    const content = try std.json.parseFromSliceLeaky(
        ChainScheme,
        alloc,
        string,
        .{ .allocate = .alloc_always },
    );
    return content.chains;
}
pub fn stringifyChains(alloc: std.mem.Allocator, chains: []Chain) ![]const u8 {
    return try std.json.stringifyAlloc(
        alloc,
        ChainScheme{ .chains = chains },
        .{ .whitespace = .indent_4 },
    );
}

const TopologySchema = struct {
    _schema_version: []const u8,
    editor: [][]const u8,
    pager: [][]const u8,
    tags: []TagInfo,
    // path to where we store the chains file
    chainpath: []const u8,
    tasklists: []TasklistInfo,
    directories: []Directory,
    journals: []Journal,
};

tags: []TagInfo,
directories: []Directory,
journals: []Journal,
tasklists: []TasklistInfo,
chainpath: []const u8,
editor: [][]const u8,
pager: [][]const u8,
mem: std.heap.ArenaAllocator,

pub fn initNew(alloc: std.mem.Allocator) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();

    const directories = try temp_alloc.alloc(Directory, 0);
    const journals = try temp_alloc.alloc(Journal, 0);
    const tasklists = try temp_alloc.alloc(TasklistInfo, 0);
    const tags = try temp_alloc.alloc(TagInfo, 0);
    const editor = try temp_alloc.dupe([]const u8, &.{"vim"});
    const pager = try temp_alloc.dupe([]const u8, &.{"less"});

    return .{
        .tags = tags,
        .directories = directories,
        .journals = journals,
        .tasklists = tasklists,
        .chainpath = DEFAULT_CHAIN_FILENAME,
        .editor = editor,
        .pager = pager,
        .mem = mem,
    };
}

pub fn init(alloc: std.mem.Allocator, data: []const u8) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    const temp_alloc = mem.allocator();
    const schema = try std.json.parseFromSliceLeaky(
        TopologySchema,
        temp_alloc,
        data,
        .{ .allocate = .alloc_always },
    );

    return .{
        .tags = schema.tags,
        .directories = schema.directories,
        .journals = schema.journals,
        .tasklists = schema.tasklists,
        .chainpath = schema.chainpath,
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
        .chainpath = self.chainpath,
        .tags = self.tags,
        .tasklists = self.tasklists,
        .editor = self.editor,
        .pager = self.pager,
    };
    return std.json.stringifyAlloc(alloc, schema, .{ .whitespace = .indent_4 });
}
