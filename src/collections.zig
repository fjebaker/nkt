const std = @import("std");
const wrappers = @import("collections/wrappers.zig");
const indexing = @import("collections/indexing.zig");

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

pub const Tag = Topology.Tag;

// union types
pub const Collection = wrappers.Collection;
pub const Item = wrappers.CollectionItem;

// specific types
pub const Directory = wrappers.DirectoryCollection;
pub const Journal = wrappers.JournalCollection;

pub const DirectoryItem = Directory.TrackedChild;
pub const JournalItem = Journal.TrackedChild;

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
        d.deinit();
    };

    for (collections) |*col| {
        const c = try T.init(alloc, col, fs);
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

pub fn writeChanges(journal: *Journal, alloc: std.mem.Allocator) !void {
    for (journal.container.infos) |*info| {
        var entry = journal.get(info.name).?;
        var children = entry.item.children orelse continue;

        // update last modified
        const modified = entry.item.lastModified();
        info.modified = modified;

        // write entries back to file
        const string = try Journal.Child.stringifyContent(alloc, children);
        defer alloc.free(string);

        try journal.fs.overwrite(info.path, string);
    }
}
