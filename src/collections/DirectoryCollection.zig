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

pub const TrackedChild = struct {
    collection: *Self,
    item: Child,

    pub fn relativePath(self: TrackedChild) []const u8 {
        return self.item.info.path;
    }
};

mem: std.heap.ArenaAllocator,
container: *Directory,
content: ContentMap,
fs: FileSystem,
index: IndexContainer,

pub usingnamespace wrappers.Mixin(Self);

pub fn addChild(
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
