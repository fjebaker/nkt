const std = @import("std");
const utils = @import("../utils.zig");

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

pub fn Mixin(
    comptime Self: type,
    comptime Item: type,
    comptime ChildType: type,
    comptime parent_field: []const u8,
    comptime prepareItem: fn (*Self, Item) ChildType,
) type {
    const ItemChild = @typeInfo(Item).Pointer.child;
    if (!@hasField(ItemChild, "name"))
        @compileError("ChildType must have 'name' field");

    if (!@hasField(Self, "index"))
        @compileError("Self must have 'index' field");

    return struct {
        pub const List = struct {
            allocator: std.mem.Allocator,
            items: []ChildType,

            pub usingnamespace utils.ListMixin(List, ChildType);

            pub fn sortBy(self: *List, ordering: Ordering) void {
                const sorter = std.sort.insertion;
                switch (ordering) {
                    .Created => sorter(ChildType, self.items, {}, ChildType.sortCreated),
                    .Modified => sorter(ChildType, self.items, {}, ChildType.sortModified),
                }
            }
        };

        pub fn getChildList(
            self: *const Self,
            alloc: std.mem.Allocator,
        ) !List {
            const items = @field(self, parent_field).infos;
            var children = try alloc.alloc(ChildType, items.len);
            errdefer alloc.free(children);

            for (children, items) |*child, *info| {
                child.* = ChildType.init(
                    info,
                    self.content.get(info.name),
                );
            }

            return List.initOwned(alloc, children);
        }

        pub fn getIndex(self: *Self, index: usize) ?ChildType {
            const name = self.index.get(index) orelse
                return null;
            return self.get(name);
        }

        pub fn get(self: *Self, name: []const u8) ?ChildType {
            var items = @field(self, parent_field).infos;
            for (items) |*item| {
                if (std.mem.eql(u8, item.name, name)) {
                    return prepareItem(self, item);
                }
            }
            return null;
        }

        pub fn remove(self: *Self, item: Item) !void {
            var items = &@field(self, parent_field).infos;
            const index = for (items.*, 0..) |i, j| {
                if (std.mem.eql(u8, i.name, item.name)) break j;
            } else unreachable; // todo: proper error
            // todo: better remove
            // this is okay since everything is arena allocator tracked?
            utils.moveToEnd(ItemChild, items.*, index);
            items.len -= 1;
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
    Note: DirectoryCollection.DirectoryItem,
    JournalEntry: JournalCollection.JournalItem,
    DirectoryJournalItems: struct {
        directory: DirectoryCollection.DirectoryItem,
        journal: JournalCollection.JournalItem,
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
