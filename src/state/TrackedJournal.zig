const std = @import("std");
const utils = @import("../utils.zig");

const Topology = @import("../Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const ContentMap = @import("ContentMap.zig");
const Ordering = @import("collections.zig").Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Self = @This();

journal_allocator: std.mem.Allocator,
journal: *Journal,
index: IndexContainer,

pub fn getDatedEntryList(
    self: *const Self,
    alloc: std.mem.Allocator,
) !DatedEntryList {
    var entries = try alloc.dupe(Journal.Entry, self.journal.entries);
    errdefer alloc.free(entries);
    return DatedEntryList.initOwnedEntries(alloc, entries);
}

const Journal = Topology.Journal;

pub const DatedEntryList = struct {
    const Entry = Journal.Entry;

    pub const DatedEntry = struct {
        created: u64,
        modified: u64,
        entry: *Entry,

        pub fn sortCreated(_: void, lhs: DatedEntry, rhs: DatedEntry) bool {
            return lhs.created < rhs.created;
        }

        pub fn sortModified(_: void, lhs: DatedEntry, rhs: DatedEntry) bool {
            return lhs.modified < rhs.modified;
        }
    };

    allocator: std.mem.Allocator,
    items: []DatedEntry,
    _entries: []Entry,

    pub usingnamespace utils.ListMixin(DatedEntryList, DatedEntry);

    pub fn _deinit(self: *DatedEntryList) void {
        self.allocator.free(self._entries);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    fn initOwnedEntries(alloc: std.mem.Allocator, entries: []Entry) !DatedEntryList {
        var items = try alloc.alloc(DatedEntry, entries.len);

        for (items, entries) |*item, *entry| {
            const created = entry.timeCreated();
            const modified = entry.lastModified();
            item.* = .{
                .created = created,
                .modified = modified,
                .entry = entry,
            };
        }

        return .{
            .allocator = alloc,
            .items = items,
            ._entries = entries,
        };
    }

    pub fn sortBy(self: *DatedEntryList, ordering: Ordering) void {
        const sorter = std.sort.insertion;
        switch (ordering) {
            .Created => sorter(
                DatedEntry,
                self.items,
                {},
                DatedEntry.sortCreated,
            ),
            .Modified => sorter(
                DatedEntry,
                self.items,
                {},
                DatedEntry.sortModified,
            ),
        }
    }
};
