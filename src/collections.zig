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
pub const TaskList = wrappers.TaskListCollection;

pub const DirectoryItem = Directory.TrackedChild;
pub const JournalItem = Journal.TrackedChild;
pub const TaskListItem = TaskList.TrackedChild;

pub const Ordering = wrappers.Ordering;

pub const CollectionType = enum {
    Directory,
    Journal,
    DirectoryWithJournal,
    TaskList,
};

pub const Collection = union(CollectionType) {
    pub const Errors = error{NoSuchCollection};
    Directory: *Directory,
    Journal: *Journal,
    DirectoryWithJournal: struct {
        journal: *Journal,
        directory: *Directory,
    },
    TaskList: *TaskList,

    pub fn initDirectoryJournal(maybe_directory: ?*Directory, maybe_journal: ?*Journal) ?Collection {
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

    pub fn hasChildName(self: *const Collection, name: []const u8) bool {
        switch (self.*) {
            .DirectoryWithJournal => unreachable,
            inline else => |i| return if (i.get(name)) |_| true else false,
        }
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

    pub fn collectionType(self: CollectionItem) CollectionType {
        return switch (self) {
            .Note => .Directory,
            .JournalEntry => .Journal,
            .DirectoryJournalItems => .DirectoryWithJournal,
        };
    }

    pub fn collectionName(self: *const CollectionItem) []const u8 {
        return switch (self.*) {
            .DirectoryJournalItems => |i| i.directory.collection.container.name,
            inline else => |i| i.collection.container.name,
        };
    }

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
    return newCollectionList(
        Directory,
        Topology.Directory,
        alloc,
        directories,
        fs,
    );
}

pub fn newJournalList(
    alloc: std.mem.Allocator,
    journals: []Topology.Journal,
    fs: FileSystem,
) ![]Journal {
    return newCollectionList(
        Journal,
        Topology.Journal,
        alloc,
        journals,
        fs,
    );
}

pub fn newTaskListList(
    alloc: std.mem.Allocator,
    tasklists: []Topology.TaskListDetails,
    fs: FileSystem,
) ![]TaskList {
    return try newCollectionList(
        TaskList,
        Topology.TaskListDetails,
        alloc,
        tasklists,
        fs,
    );
}

pub fn writeChanges(
    collection: anytype,
    alloc: std.mem.Allocator,
) !void {
    if (@typeInfo(@TypeOf(collection)) != .Pointer)
        @compileError("Must be a pointer");

    for (collection.container.infos) |*info| {
        var entry = collection.get(info.name).?;
        var children = entry.item.children orelse continue;

        // update last modified
        const modified = entry.item.lastModified();
        info.modified = modified;

        // write entries back to file
        const string = try Journal.Child.stringifyContent(alloc, children);
        defer alloc.free(string);

        try collection.fs.overwrite(info.path, string);
    }
}
