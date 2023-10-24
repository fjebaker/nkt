const std = @import("std");
const utils = @import("../utils.zig");

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

pub fn Mixin(
    comptime Self: type,
) type {
    const InfoPtr = *Self.Child.Info;
    const Child = Self.Child;

    return struct {
        pub const List = struct {
            allocator: std.mem.Allocator,
            items: []Child,

            pub usingnamespace utils.ListMixin(List, Child);

            pub fn sortBy(self: *List, ordering: Ordering) void {
                const sorter = std.sort.insertion;
                switch (ordering) {
                    .Created => sorter(Child, self.items, {}, Child.sortCreated),
                    .Modified => sorter(Child, self.items, {}, Child.sortModified),
                }
            }
        };

        pub fn getChildList(
            self: *const Self,
            alloc: std.mem.Allocator,
        ) !List {
            const items = self.container.infos;
            var children = try alloc.alloc(Child, items.len);
            errdefer alloc.free(children);

            for (children, items) |*child, *info| {
                child.* = Child.init(
                    info,
                    self.content.get(info.name),
                );
            }

            return List.initOwned(alloc, children);
        }

        pub fn getIndex(self: *Self, index: usize) ?Self.TrackedChild {
            const name = self.index.get(index) orelse
                return null;
            return self.get(name);
        }

        fn prepareChild(self: *Self, info: InfoPtr) Self.TrackedChild {
            var item: Child = .{ .children = self.content.get(info.name), .info = info };
            return .{ .collection = self, .item = item };
        }

        /// Get the child by name. Will not attempt to read the file with the
        /// child's content until `ensureContent` is called on the Child.
        pub fn get(self: *Self, name: []const u8) ?Self.TrackedChild {
            var items = self.container.infos;
            for (items) |*item| {
                if (std.mem.eql(u8, item.name, name)) {
                    return prepareChild(self, item);
                }
            }
            return null;
        }

        pub fn remove(self: *Self, item: InfoPtr) !void {
            var items = &self.container.infos;
            const index = for (items.*, 0..) |i, j| {
                if (std.mem.eql(u8, i.name, item.name)) break j;
            } else unreachable; // todo: proper error
            // todo: better remove
            // this is okay since everything is arena allocator tracked?
            utils.moveToEnd(Child.Info, items.*, index);
            items.len -= 1;
        }

        pub fn collectionName(self: *const Self) []const u8 {
            return self.container.name;
        }
    };
}

pub const DirectoryCollection = @import("DirectoryCollection.zig");
pub const JournalCollection = @import("JournalCollection.zig");

pub const Ordering = enum { Modified, Created };

pub const CollectionType = enum { Directory, Journal, DirectoryWithJournal };

pub const Collection = union(CollectionType) {
    pub const Errors = error{NoSuchCollection};
    Directory: *DirectoryCollection,
    Journal: *JournalCollection,
    DirectoryWithJournal: struct {
        journal: *JournalCollection,
        directory: *DirectoryCollection,
    },

    pub fn init(maybe_directory: ?*DirectoryCollection, maybe_journal: ?*JournalCollection) ?Collection {
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

pub const TrackedItem = union(ItemType) {
    Note: DirectoryCollection.TrackedChild,
    JournalEntry: JournalCollection.TrackedChild,
    DirectoryJournalItems: struct {
        directory: DirectoryCollection.TrackedChild,
        journal: JournalCollection.TrackedChild,
    },

    pub fn remove(self: *TrackedItem) !void {
        switch (self.*) {
            .DirectoryJournalItems => unreachable, // todo
            inline else => |c| try c.collection.remove(c.item.info),
        }
    }

    pub fn ensureContent(self: *TrackedItem) !void {
        switch (self.*) {
            .DirectoryJournalItems => |*both| {
                try both.directory.collection.readCollectionContent(
                    &both.directory.item,
                );
                try both.journal.collection.readCollectionContent(
                    &both.journal.item,
                );
            },
            inline else => |*collection| {
                try collection.collection.readCollectionContent(
                    &collection.item,
                );
            },
        }
    }
};
