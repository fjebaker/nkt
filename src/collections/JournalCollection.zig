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

pub usingnamespace wrappers.Mixin(
    Self,
    *Child.Info,
    Child,
    "container",
    prepareItem,
);

fn prepareItem(self: *Self, info: *Child.Info) Child {
    return .{
        .info = info,
        .children = self.content.get(info.name),
    };
}

pub const JournalError = error{DuplicateEntry};

pub const JournalItem = struct {
    collection: *Self,
    item: Child,

    pub fn relativePath(self: JournalItem) []const u8 {
        return self.item.info.path;
    }

    pub fn add(self: *JournalItem, text: []const u8) !void {
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

    pub fn remove(self: *JournalItem, item: Child.Item) !void {
        const index = for (self.item.children.?, 0..) |i, j| {
            if (i.created == item.created) break j;
        } else unreachable; // todo
        utils.moveToEnd(Child.Item, self.item.children.?, index);
        self.item.children.?.len -= 1;
        try self.collection.content.putMove(self.item.info.name, self.item.children.?);
    }
};

const ItemScheme = struct { items: []Child.Item };

fn readItems(self: *Self, info: Child.Info) ![]Child.Item {
    var alloc = self.content.allocator();

    const string = try self.fs.readFileAlloc(
        alloc,
        info.path,
    );
    defer alloc.free(string);

    var content = try std.json.parseFromSliceLeaky(
        ItemScheme,
        alloc,
        string,
        .{ .allocate = .alloc_always },
    );

    try self.content.putMove(info.name, content.items);
    return content.items;
}

fn itemsToString(alloc: std.mem.Allocator, items: []Child.Item) ![]const u8 {
    return try std.json.stringifyAlloc(
        alloc,
        ItemScheme{ .items = items },
        .{ .whitespace = .indent_4 },
    );
}

pub fn addItem(self: *Self, entry: *Child, item: Child.Item) !void {
    var alloc = self.content.allocator();

    try self.readCollectionContent(entry);
    var children = entry.children.?;

    _ = try utils.push(Child.Item, alloc, &children, item);
    entry.children = children;
    try self.content.putMove(entry.getName(), entry.children.?);
}

pub fn readCollectionContent(self: *Self, entry: *Child) !void {
    if (entry.children == null) {
        entry.children = try self.readItems(entry.info.*);
    }
}

pub fn getEntryByDate(self: *Self, date: utils.Date) ?JournalItem {
    for (self.container.infos) |*entry| {
        const entry_date = utils.Date.initUnixMs(entry.timeCreated());
        if (utils.areSameDay(entry_date, date)) {
            return .{ .collection = self, .item = entry };
        }
    }
    return null;
}

pub fn getEntryByName(self: *Self, name: []const u8) ?JournalItem {
    for (self.container.infos) |*info| {
        if (std.mem.eql(u8, info.name, name)) {
            return .{
                .collection = self,
                .item = .{
                    .info = info,
                    .children = self.content.get(info.name),
                },
            };
        }
    }
    return null;
}

fn assertNoDuplicate(self: *Self, name: []const u8) !void {
    if (self.getEntryByName(name)) |_| return JournalError.DuplicateEntry;
}

fn addEntry(
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

fn childPath(self: *Self, name: []const u8) ![]const u8 {
    const alloc = self.mem.allocator();
    const filename = try std.mem.concat(
        alloc,
        u8,
        &.{ name, DEFAULT_FILE_EXTENSION },
    );
    return try std.fs.path.join(
        alloc,
        &.{ self.container.path, filename },
    );
}

pub fn newChild(
    self: *Self,
    name: []const u8,
) !JournalItem {
    var alloc = self.mem.allocator();
    try self.assertNoDuplicate(name);

    var owned_name = try alloc.dupe(u8, name);

    const now = utils.now();
    const info: Child.Info = .{
        .modified = now,
        .created = now,
        .name = owned_name,
        .path = try self.childPath(owned_name),
        .tags = try utils.emptyTagList(alloc),
    };

    var entry = try self.addEntry(info, null);
    return .{ .collection = self, .item = entry };
}

pub fn writeChanges(self: *Self, alloc: std.mem.Allocator) !void {
    for (self.container.infos) |*info| {
        var entry = self.getEntryByName(info.name).?;
        var children = entry.item.children orelse continue;

        // update last modified
        const modified = entry.item.lastModified();
        info.modified = modified;

        // write entries back to file
        const string = try itemsToString(alloc, children);
        defer alloc.free(string);

        try self.fs.overwrite(info.path, string);
    }
}
