const std = @import("std");
const utils = @import("../utils.zig");

const content_map = @import("content_map.zig");

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const wrappers = @import("wrappers.zig");
const Ordering = wrappers.Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Journal = Topology.Journal;
const Self = @This();

pub const DEFAULT_FILE_EXTENSION = ".json";
pub const ContentMap = content_map.ContentMap([]Topology.Entry.Item);

// public interface for getting the subtypes
pub const Parent = Journal;
pub const Child = Topology.Entry;

mem: std.heap.ArenaAllocator,
container: *Journal,
content: ContentMap,
fs: FileSystem,
index: IndexContainer,

pub usingnamespace wrappers.Mixin(Self);

pub const JournalError = error{DuplicateEntry};

pub const TrackedChild = struct {
    collection: *Self,
    item: Child,

    pub fn relativePath(self: TrackedChild) []const u8 {
        return self.item.info.path;
    }

    pub fn add(self: *TrackedChild, text: []const u8) !void {
        var alloc = self.collection.content.allocator();
        const now = utils.now();
        const owned_text = try alloc.dupe(u8, text);

        const item: Child.Item = .{
            .created = now,
            .modified = now,
            .item = owned_text,
            .tags = try utils.emptyTagList(alloc),
        };

        try self.collection.addItem(&self.item, item);
    }

    pub fn remove(self: *TrackedChild, item: Child.Item) !void {
        const index = for (self.item.children.?, 0..) |i, j| {
            if (i.created == item.created) break j;
        } else unreachable; // todo
        utils.moveToEnd(Child.Item, self.item.children.?, index);
        self.item.children.?.len -= 1;
        try self.collection.content.putMove(self.item.info.name, self.item.children.?);
    }
};

fn addItem(self: *Self, entry: *Child, item: Child.Item) !void {
    var alloc = self.content.allocator();

    try self.readChildContent(entry);
    var children = entry.children.?;

    _ = try utils.push(Child.Item, alloc, &children, item);
    entry.children = children;
    try self.content.putMove(entry.getName(), entry.children.?);
}

fn assertNoDuplicate(self: *Self, name: []const u8) !void {
    if (self.get(name)) |_| return JournalError.DuplicateEntry;
}

pub fn addChild(
    self: *Self,
    info: Child.Info,
    items: ?[]Child.Item,
) !Child {
    var alloc = self.mem.allocator();
    const info_ptr = try utils.push(
        Child.Info,
        alloc,
        &self.container.infos,
        info,
    );

    if (items) |i| {
        try self.content.put(info.name, i);
    }

    // create a corresponding file in the filesystem
    try self.fs.overwrite(info.path, "{\"items\":[]}");

    return .{
        .info = info_ptr,
        .children = self.content.get(info.name),
    };
}

pub fn writeChanges(self: *Self, alloc: std.mem.Allocator) !void {
    for (self.container.infos) |*info| {
        var entry = self.get(info.name).?;
        var children = entry.item.children orelse continue;

        // update last modified
        const modified = entry.item.lastModified();
        info.modified = modified;

        // write entries back to file
        const string = try Child.stringifyContent(alloc, children);
        defer alloc.free(string);

        try self.fs.overwrite(info.path, string);
    }
}
