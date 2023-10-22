const std = @import("std");
const utils = @import("../utils.zig");

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const ContentMap = @import("ContentMap.zig");
const wrappers = @import("wrappers.zig");
const Ordering = wrappers.Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Journal = Topology.Journal;
const Self = @This();

mem: std.heap.ArenaAllocator,
journal_allocator: std.mem.Allocator,
journal: *Journal,
index: IndexContainer,

// public interface for getting the subtypes
pub const Parent = Journal;
pub const Child = Journal.Entry;

pub const JournalError = error{DuplicateEntry};

pub const JournalItem = struct {
    collection: *Self,
    item: *Journal.Entry,

    pub fn add(self: *JournalItem, text: []const u8) !void {
        var alloc = self.collection.mem.allocator();
        const now = utils.now();
        const owned_text = try alloc.dupe(u8, text);
        const item: Journal.Entry.Item = .{
            .created = now,
            .modified = now,
            .item = owned_text,
        };
        _ = try utils.push(
            Journal.Entry.Item,
            alloc,
            &self.item.items,
            item,
        );
    }
};

pub usingnamespace wrappers.Mixin(
    Self,
    *Journal.Entry,
    *Journal.Entry,
    "journal",
    "entries",
    prepareItem,
);

fn prepareItem(_: *Self, entry: *Journal.Entry) *Journal.Entry {
    return entry;
}

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

pub fn getDatedEntryList(
    self: *const Self,
    alloc: std.mem.Allocator,
) !DatedEntryList {
    var entries = try alloc.dupe(Journal.Entry, self.journal.entries);
    errdefer alloc.free(entries);
    return DatedEntryList.initOwnedEntries(alloc, entries);
}

pub fn getEntryByDate(self: *Self, date: utils.Date) ?JournalItem {
    for (self.journal.entries) |*entry| {
        const entry_date = utils.Date.initUnixMs(entry.timeCreated());
        if (utils.areSameDay(entry_date, date)) {
            return .{ .collection = self, .item = entry };
        }
    }
    return null;
}

pub fn getEntryByName(self: *Self, name: []const u8) ?JournalItem {
    for (self.journal.entries) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return .{ .collection = self, .item = entry };
        }
    }
    return null;
}

fn assertNoDuplicate(self: *Self, name: []const u8) !void {
    if (self.getEntryByName(name)) |_| return JournalError.DuplicateEntry;
}

pub fn newChild(
    self: *Self,
    name: []const u8,
) !JournalItem {
    var alloc = self.mem.allocator();
    try self.assertNoDuplicate(name);

    var owned_name = try alloc.dupe(u8, name);

    const path = ""; // todo

    var entry: Journal.Entry = .{
        .items = try alloc.alloc(Journal.Entry.Item, 0),
        .name = owned_name,
        .path = path,
    };

    const entry_ptr = try utils.push(
        Journal.Entry,
        self.journal_allocator,
        &(self.journal.entries),
        entry,
    );
    return .{ .collection = self, .item = entry_ptr };
}
