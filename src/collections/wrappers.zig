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
    comptime child_field: []const u8,
    comptime prepareItem: fn (*Self, Item) ChildType,
) type {
    if (!@hasField(@typeInfo(Item).Pointer.child, "name"))
        @compileError("ChildType must have 'name' field");

    if (!@hasField(Self, "index"))
        @compileError("Self must have 'index' field");

    return struct {
        pub fn getIndex(self: *Self, index: usize) ?ChildType {
            const name = self.index.get(index) orelse
                return null;
            return self.get(name);
        }

        pub fn get(self: *Self, name: []const u8) ?ChildType {
            var items = @field(@field(self, parent_field), child_field);
            for (items) |*item| {
                if (std.mem.eql(u8, item.name, name)) {
                    return prepareItem(self, item);
                }
            }
            return null;
        }
    };
}

pub const ContentMap = @import("ContentMap.zig");
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

    pub fn ensureContent(self: *TrackedItem) !void {
        switch (self.*) {
            .Note => |*note_directory| {
                try note_directory.collection.readNoteContent(
                    &note_directory.item,
                );
            },
            .DirectoryJournalItems => |*both| {
                try both.directory.collection.readNoteContent(
                    &both.directory.item,
                );
            },
            else => {},
        }
    }
};
