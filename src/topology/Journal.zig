const std = @import("std");
const Time = @import("time.zig").Time;
const tags = @import("tags.zig");
const Tag = tags.Tag;
const FileSystem = @import("../FileSystem.zig");

const Journal = @This();

pub const TOPOLOGY_FILENAME = "topology.json";

pub const Error = error{NoSuchDay};

pub const Entry = struct {
    text: []const u8,
    created: Time,
    modified: Time,
    tags: []Tag,

    pub fn sortCreated(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.created < rhs.created;
    }
};

// Only used for (de)serializing an entry list
const EntryWrapper = struct {
    entries: []Entry,
};

pub const Day = struct {
    path: []const u8,
    name: []const u8,
    created: Time,
    modified: Time,
    tags: []Tag,
};

pub const Info = struct {
    tags: []Tag = &.{},
    days: []Day = &.{},
};

const StagedEntries = std.StringHashMap(std.ArrayList(Entry));

info: *Info,
allocator: std.mem.Allocator,
staged_entries: ?StagedEntries = null,
fs: ?FileSystem = null,
mem: ?std.heap.ArenaAllocator = null,

fn getStagedEntries(self: *Journal) *StagedEntries {
    if (self.staged_entries == null) {
        self.staged_entries = StagedEntries.init(self.allocator);
    }
    return &self.staged_entries.?;
}

fn getTmpAllocator(self: *Journal) std.mem.Allocator {
    if (self.mem == null) {
        self.mem = std.heap.ArenaAllocator.init(self.allocator);
    }
    return self.mem.?.allocator();
}

pub fn deinit(self: *Journal) void {
    if (self.staged_entries) |*se| {
        var itt = se.iterator();
        while (itt.next()) |entry| {
            entry.value_ptr.deinit();
        }
        se.deinit();
    }
    if (self.mem) |*mem| mem.deinit();
    self.* = undefined;
}

/// Add a new day to the journal. No strings are copied, so it is
/// assumed the contents of the `day` will outlive the `Journal`.
pub fn addNewDay(self: *Journal, day: Day) !void {
    var list = std.ArrayList(Day).fromOwnedSlice(
        self.allocator,
        self.info.days,
    );
    try list.append(day);
    self.info.days = try list.toOwnedSlice();
}

fn readDayFromPath(
    self: *Journal,
    fs: *FileSystem,
    path: []const u8,
) ![]Entry {
    var alloc = self.getTmpAllocator();
    const content = try fs.readFileAlloc(alloc, path);
    const parsed = try std.json.parseFromSliceLeaky(
        EntryWrapper,
        alloc,
        content,
        .{},
    );
    return self.allocator.dupe(Entry, parsed.entries);
}

fn addDayToStage(
    self: *Journal,
    map: *StagedEntries,
    path: []const u8,
) !void {
    if (self.fs) |*fs| {
        // read entries and init owned list
        var entries = try self.readDayFromPath(fs, path);
        try map.put(path, std.ArrayList(Entry).fromOwnedSlice(
            self.allocator,
            entries,
        ));
    } else {
        // else create empty list
        try map.put(path, std.ArrayList(Entry).init(self.allocator));
    }
}

fn getDayIndex(self: *Journal, day_name: []const u8) ?usize {
    for (0.., self.info.days) |i, day| {
        if (std.mem.eql(u8, day_name, day.name)) {
            return i;
        }
    }
    return null;
}

/// Add an `Entry` to the day with name `day_name`. Does not write to file
/// until `writeChanges` is called.
pub fn addNewEntryToPath(
    self: *Journal,
    path: []const u8,
    entry: Entry,
) !void {
    var map = self.getStagedEntries();
    if (!map.contains(path)) {
        try self.addDayToStage(map, path);
    }
    var ptr = map.getPtr(path).?;
    try ptr.append(entry);
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Journal.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Caller owns memory
pub fn serialize(self: *Journal, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
