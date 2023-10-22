const std = @import("std");
const wrappers = @import("collections/wrappers.zig");
const indexing = @import("collections/indexing.zig");

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

const ContentMap = wrappers.ContentMap;

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

pub fn newDirectoryList(
    alloc: std.mem.Allocator,
    directory_allocator: std.mem.Allocator,
    directories: []Topology.Directory,
    fs: FileSystem,
) ![]Directory {
    var list = try std.ArrayList(Directory).initCapacity(alloc, directories.len);
    errdefer list.deinit();
    errdefer for (list.items) |*d| {
        d.index.deinit();
        d.content.deinit();
    };

    for (directories) |*dir| {
        var content = try ContentMap.init(alloc);
        errdefer content.deinit();

        var index = try indexing.makeIndex(alloc, dir.infos);
        errdefer index.deinit();

        const nd: Directory = .{
            .content = content,
            .directory = dir,
            .directory_allocator = directory_allocator,
            .fs = fs,
            .index = index,
        };

        list.appendAssumeCapacity(nd);
    }

    return try list.toOwnedSlice();
}

pub fn newJournalList(
    alloc: std.mem.Allocator,
    journal_allocator: std.mem.Allocator,
    journals: []Topology.Journal,
    _: FileSystem,
) ![]Journal {
    var list = try std.ArrayList(Journal).initCapacity(alloc, journals.len);
    errdefer list.deinit();
    errdefer for (list.items) |*d| {
        d.index.deinit();
    };

    for (journals) |*j| {
        var index = try indexing.makeIndex(alloc, j.entries);
        errdefer index.deinit();

        const tj: Journal = .{
            .mem = std.heap.ArenaAllocator.init(alloc),
            .journal_allocator = journal_allocator,
            .journal = j,
            .index = index,
        };

        list.appendAssumeCapacity(tj);
    }

    return try list.toOwnedSlice();
}
