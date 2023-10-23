const std = @import("std");
const utils = @import("../utils.zig");

const content_map = @import("content_map.zig");

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const wrappers = @import("wrappers.zig");
const Ordering = wrappers.Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Directory = Topology.Directory;
const Self = @This();

pub const DEFAULT_FILE_EXTENSION = ".md";
pub const ContentMap = content_map.ContentMap([]const u8);

// public interface for getting the subtypes
pub const Parent = Directory;
pub const Child = Topology.Note;

pub const DirectoryItem = struct {
    collection: *Self,
    item: Child,

    pub fn relativePath(self: DirectoryItem) []const u8 {
        return self.item.info.path;
    }
};

mem: std.heap.ArenaAllocator,
container: *Directory,
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

/// Reads note. Will return null if note does not exist. Does not
/// attempt to read the note content. Use `readNote` to attempt to
/// read content
pub fn getNote(self: *Self, name: []const u8) ?Child {
    for (self.container.infos) |*info| {
        if (std.mem.eql(u8, info.name, name)) {
            return .{
                .info = info,
                .content = self.content.get(name),
            };
        }
    }
    return null;
}

fn readContent(self: *Self, info: Child.Info) ![]const u8 {
    var alloc = self.content.allocator();
    const content = try self.fs.readFileAlloc(alloc, info.path);
    try self.content.putMove(info.name, content);
    return content;
}

pub fn readNote(self: *Self, name: []const u8) !?Child {
    var note = self.getNote(name) orelse return null;
    note.children = try self.readContent(note.info.*);
    return note;
}

pub fn readCollectionContent(self: *Self, entry: *Child) !void {
    if (entry.children == null) {
        entry.children = try self.readContent(entry.info.*);
    }
}

pub fn addNote(
    self: *Self,
    info: Child.Info,
    content: ?[]const u8,
) !Child {
    var alloc = self.mem.allocator();
    const info_ptr = try utils.push(
        Child.Info,
        alloc,
        &self.container.infos,
        info,
    );

    if (content) |c| {
        try self.content.put(info.name, c);
    }

    return .{
        .info = info_ptr,
        .children = self.content.get(info.name),
    };
}

fn childPath(self: *Self, name: []const u8) ![]const u8 {
    var alloc = self.mem.allocator();
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
) !DirectoryItem {
    var alloc = self.mem.allocator();
    const owned_name = try alloc.dupe(u8, name);

    const now = utils.now();
    const info: Child.Info = .{
        .modified = now,
        .created = now,
        .name = owned_name,
        .path = try self.childPath(owned_name),
        .tags = try utils.emptyTagList(alloc),
    };

    var note = try self.addNote(info, null);
    return .{ .collection = self, .item = note };
}
