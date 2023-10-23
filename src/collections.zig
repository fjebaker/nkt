const std = @import("std");
const wrappers = @import("collections/wrappers.zig");
const indexing = @import("collections/indexing.zig");

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

pub const Tag = Topology.Tag;

// union types
pub const Collection = wrappers.Collection;
pub const Item = wrappers.TrackedItem;

// specific types
pub const Directory = wrappers.DirectoryCollection;
pub const Journal = wrappers.JournalCollection;

pub const DirectoryItem = Directory.DirectoryItem;
pub const JournalItem = Journal.JournalItem;

// enums
pub const CollectionType = wrappers.CollectionType;
pub const ItemType = wrappers.ItemType;

pub const Ordering = wrappers.Ordering;

fn newCollectionList(
    comptime T: type,
    comptime K: type,
    alloc: std.mem.Allocator,
    collections: []K,
    fs: FileSystem,
) ![]T {
    var list = try std.ArrayList(T).initCapacity(alloc, collections.len);
    errdefer list.deinit();
    errdefer for (list.items) |*d| {
        d.index.deinit();
        d.content.deinit();
    };

    for (collections) |*col| {
        var content = try T.ContentMap.init(alloc);
        errdefer content.deinit();

        var index = try indexing.makeIndex(alloc, col.infos);
        errdefer index.deinit();

        const c: T = .{
            .mem = std.heap.ArenaAllocator.init(alloc),
            .content = content,
            .container = col,
            .fs = fs,
            .index = index,
        };

        list.appendAssumeCapacity(c);
    }

    return try list.toOwnedSlice();
}

pub fn newDirectoryList(
    alloc: std.mem.Allocator,
    directories: []Topology.Directory,
    fs: FileSystem,
) ![]Directory {
    return newCollectionList(Directory, Topology.Directory, alloc, directories, fs);
}

pub fn newJournalList(
    alloc: std.mem.Allocator,
    journals: []Topology.Journal,
    fs: FileSystem,
) ![]Journal {
    return newCollectionList(Journal, Topology.Journal, alloc, journals, fs);
}
