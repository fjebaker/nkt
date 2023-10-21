const std = @import("std");
const utils = @import("../utils.zig");

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Topology = @import("../Topology.zig");
const FileSystem = @import("../FileSystem.zig");

pub const ContentMap = @import("ContentMap.zig");
pub const NotesDirectory = @import("NotesDirectory.zig");
pub const TrackedJournal = @import("TrackedJournal.zig");

pub const Ordering = enum { Modified, Created };

pub const CollectionType = enum { Directory, Journal, DirectoryWithJournal };

pub const Collection = union(CollectionType) {
    pub const Errors = error{NoSuchCollection};
    Directory: *NotesDirectory,
    Journal: *TrackedJournal,
    DirectoryWithJournal: struct {
        journal: *TrackedJournal,
        directory: *NotesDirectory,
    },

    pub fn init(maybe_directory: ?*NotesDirectory, maybe_journal: ?*TrackedJournal) ?Collection {
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

pub const ItemType = enum { Note, JournalEntry, NoteWithJournalEntry };

pub const TrackedItem = union(ItemType) {
    fn Item(comptime CT: type, comptime IT: type) type {
        return struct { collection: CT, item: IT };
    }

    const _NoteType = Item(*NotesDirectory, *Topology.Note);
    const _JournalEntry = Item(*Topology.Journal, *Topology.Journal.Entry);

    Note: _NoteType,
    JournalEntry: _JournalEntry,
    NoteWithJournalEntry: struct {
        note: _NoteType,
        journal: _JournalEntry,
    },
};

pub fn Mixin(
    comptime Self: type,
    comptime Item: type,
    comptime Child: type,
    comptime parent_field: []const u8,
    comptime child_field: []const u8,
    comptime prepareItem: fn (*Self, *Item) *Child,
) type {
    if (!@hasField(Item, "name"))
        @compileError("Child must have 'name' field");

    if (!@hasField(Self, "index"))
        @compileError("Self must have 'index' field");

    return struct {
        pub fn getIndex(self: *Self, index: usize) ?*Child {
            const name = self.index.get(index) orelse
                return null;
            return self.get(name);
        }

        pub fn get(self: *Self, name: []const u8) ?*Child {
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

pub fn newNotesDirectoryList(
    alloc: std.mem.Allocator,
    directory_allocator: std.mem.Allocator,
    directories: []Topology.Directory,
    fs: FileSystem,
) ![]NotesDirectory {
    var list = try std.ArrayList(NotesDirectory).initCapacity(alloc, directories.len);
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

        const nd: NotesDirectory = .{
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

pub fn newTrackedJournalList(
    alloc: std.mem.Allocator,
    journal_allocator: std.mem.Allocator,
    journals: []Topology.Journal,
    _: FileSystem,
) ![]TrackedJournal {
    var list = try std.ArrayList(TrackedJournal).initCapacity(alloc, journals.len);
    errdefer list.deinit();
    errdefer for (list.items) |*d| {
        d.index.deinit();
    };

    for (journals) |*j| {
        var index = try indexing.makeIndex(alloc, j.entries);
        errdefer index.deinit();

        const tj: TrackedJournal = .{
            .journal_allocator = journal_allocator,
            .journal = j,
            .index = index,
        };

        list.appendAssumeCapacity(tj);
    }

    return try list.toOwnedSlice();
}
