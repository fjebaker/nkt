const std = @import("std");
const wrappers = @import("collections/wrappers.zig");
const indexing = @import("collections/indexing.zig");

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

pub const Tag = Topology.Tag;

// union types
pub const Item = CollectionItem;

// specific types
pub const Directory = wrappers.DirectoryCollection;
pub const Journal = wrappers.JournalCollection;

pub const DirectoryItem = Directory.TrackedChild;
pub const JournalItem = Journal.TrackedChild;

pub const Ordering = wrappers.Ordering;

pub const CollectionType = enum { Directory, Journal, DirectoryWithJournal };

pub const Collection = union(CollectionType) {
    pub const Errors = error{NoSuchCollection};
    Directory: *Directory,
    Journal: *Journal,
    DirectoryWithJournal: struct {
        journal: *Journal,
        directory: *Directory,
    },

    pub fn init(maybe_directory: ?*Directory, maybe_journal: ?*Journal) ?Collection {
        if (maybe_directory != null and maybe_journal != null) {
            return .{
                .DirectoryWithJournal = .{
                    .journal = maybe_journal.?,
                    .directory = maybe_directory.?,
                },
            };
        } else if (maybe_journal) |journal| {
            return .{ .Journal = journal };
        } else if (maybe_directory) |dir| {
            return .{ .Directory = dir };
        }
        return null;
    }
};

pub const ItemType = enum { Note, JournalEntry, DirectoryJournalItems };

pub const CollectionItem = union(ItemType) {
    Note: Directory.TrackedChild,
    JournalEntry: Journal.TrackedChild,
    DirectoryJournalItems: struct {
        directory: Directory.TrackedChild,
        journal: Journal.TrackedChild,
    },

    pub fn remove(self: *CollectionItem) !void {
        switch (self.*) {
            .DirectoryJournalItems => unreachable, // todo
            inline else => |c| try c.collection.remove(c.item.info),
        }
    }

    pub fn ensureContent(self: *CollectionItem) !void {
        switch (self.*) {
            .DirectoryJournalItems => |*both| {
                try both.directory.collection.readChildContent(
                    &both.directory.item,
                );
                try both.journal.collection.readChildContent(
                    &both.journal.item,
                );
            },
            inline else => |*collection| {
                try collection.collection.readChildContent(
                    &collection.item,
                );
            },
        }
    }
};

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
