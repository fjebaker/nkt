const std = @import("std");
const time = @import("time.zig");
const Time = time.Time;
const tags = @import("tags.zig");
const Tag = tags.Tag;
const FileSystem = @import("../FileSystem.zig");
const Descriptor = @import("Root.zig").Descriptor;

const Journal = @This();

pub const TOPOLOGY_FILENAME = "topology.json";
pub const DAY_FILE_EXTENSION = "json";
pub const PATH_PREFIX = "journal";

pub const Error = error{ NoSuchDay, NoSuchEntry };

pub const Entry = struct {
    text: []const u8,
    created: Time,
    modified: Time,
    tags: []const Tag,

    pub fn sortCreated(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.created < rhs.created;
    }
};

// Only used for (de)serializing an entry list
const EntryWrapper = struct {
    entries: []const Entry,
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
descriptor: Descriptor,
allocator: std.mem.Allocator,
tag_list: ?*tags.DescriptorList = null,
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
        se.deinit();
    }
    if (self.mem) |*mem| mem.deinit();
    self.* = undefined;
}

fn timeToName(allocator: std.mem.Allocator, t: Time) ![]const u8 {
    // TODO: timezone conversion?
    const date = time.dateFromTime(t);
    const fmtd = try time.formatDateBuf(date);
    return try allocator.dupe(u8, &fmtd);
}

/// Add a new day to the journal. No strings are copied, so it is
/// assumed the contents of the `day` will outlive the `Journal`.
pub fn addNewDay(self: *Journal, day: Day) !void {
    var list = std.ArrayList(Day).fromOwnedSlice(
        self.getTmpAllocator(),
        self.info.days,
    );
    try list.append(day);
    self.info.days = try list.toOwnedSlice();
}

/// Get a day by name. Returns `null` if day not found.
pub fn getDay(self: *Journal, name: []const u8) ?Day {
    for (self.info.days) |d| {
        if (std.mem.eql(u8, d.name, name)) {
            return d;
        }
    }
    return null;
}

/// Get the `Day` by index from a reference time. That is, index 0 will be the
/// same day as the reference time, index 1 will be the day before, index n
/// will be n days before. Will not make any timezone adjustments. Returns
/// `null` if no `Day` at given index.
pub fn getDayOffsetIndex(
    self: *Journal,
    reference: time.Time,
    index: usize,
) ?Day {
    const date = time.shiftBack(reference, index);

    // TODO: is this alright?
    const name = time.formatDateBuf(date) catch return null;
    return self.getDay(&name);
}

/// Get a day by path. Returns `null` if day not found.
pub fn getDayByPath(self: *Journal, name: []const u8) ?Day {
    for (self.info.days) |d| {
        if (std.mem.eql(u8, d.name, name)) {
            return d;
        }
    }
    return null;
}

/// Get the day with `name` or else create a new day with that name.
pub fn getDayOrNew(self: *Journal, name: []const u8) !Day {
    return self.getDay(name) orelse {
        const new = try self.newDayFromName(name);
        try self.addNewDay(new);
        return new;
    };
}

fn newDayFromName(self: *Journal, name: []const u8) !Day {
    const now = time.timeNow();
    const day = Day{
        .name = name,
        .path = try self.newPathFromName(name),
        .created = now,
        .modified = now,
        .tags = &.{},
    };

    // then add to the staging so we don't try to open a file that doesn't
    // exist
    var map = self.getStagedEntries();
    try map.put(
        day.path,
        std.ArrayList(Entry).init(self.getTmpAllocator()),
    );
    return day;
}

fn newPathFromName(self: *Journal, name: []const u8) ![]const u8 {
    const dirname = std.fs.path.dirname(self.descriptor.path).?;
    var alloc = self.getTmpAllocator();
    return std.fs.path.join(
        alloc,
        &.{ dirname, try std.mem.join(
            alloc,
            ".",
            &.{ name, DAY_FILE_EXTENSION },
        ) },
    );
}

/// Remove an entry from a day.
pub fn removeEntryFromDay(self: *Journal, day: Day, entry: Entry) !void {
    var map = self.getStagedEntries();
    var list = map.getPtr(day.path) orelse return Error.NoSuchDay;
    // need to get the index of the entry in the list
    const index = b: {
        for (list.items, 0..) |e, i| {
            if (e.created == entry.created) {
                break :b i;
            }
        }
        return Error.NoSuchEntry;
    };

    _ = list.orderedRemove(index);
}

/// Remove an entire day from the journal. Also attempts to delete files if a
/// filesystem is given.
pub fn removeDay(self: *Journal, day: Day) !void {
    var list = std.ArrayList(Day).fromOwnedSlice(
        self.getTmpAllocator(),
        self.info.days,
    );

    const index = b: {
        for (list.items, 0..) |d, i| {
            if (d.created == day.created) {
                break :b i;
            }
        }
        return Error.NoSuchDay;
    };

    _ = list.orderedRemove(index);
    self.info.days = try list.toOwnedSlice();

    var map = self.getStagedEntries();
    if (map.contains(day.path)) {
        _ = map.remove(day.path);
    }

    // try and remove associated file
    var fs = self.fs orelse {
        std.log.default.debug("Cannot remove day file as no file system", .{});
        return;
    };
    try fs.removeFile(day.path);
}

/// Read the entries of a `Day`. Does not validate the day exists.
pub fn getEntries(self: *Journal, day: Day) ![]const Entry {
    // check if we have the entries staged already
    var map = self.getStagedEntries();
    if (map.get(day.path)) |entry_list| {
        return entry_list.items;
    }
    // otherwise we read from file
    var fs = self.fs orelse return error.NeedsFileSystem;

    var entries = try self.readDayFromPath(&fs, day.path);

    // add to the chache
    try map.put(day.path, std.ArrayList(Entry).fromOwnedSlice(
        self.getTmpAllocator(),
        entries,
    ));
    return entries;
}

fn readDayFromPath(
    self: *Journal,
    fs: *FileSystem,
    path: []const u8,
) ![]Entry {
    var alloc = self.getTmpAllocator();
    const content = fs.readFileAlloc(alloc, path) catch |err| {
        if (err == error.FileNotFound) {
            std.log.default.warn(
                "Day entry exists in journal, but no file found for: {s}",
                .{path},
            );
            return &.{};
        } else return err;
    };
    const parsed = try std.json.parseFromSliceLeaky(
        EntryWrapper,
        alloc,
        content,
        .{},
    );
    return try alloc.dupe(Entry, parsed.entries);
}

fn writeEntriesToPath(
    self: *Journal,
    fs: FileSystem,
    entries: []const Entry,
    path: []const u8,
) !void {
    const string = try std.json.stringifyAlloc(
        self.allocator,
        EntryWrapper{ .entries = entries },
        .{ .whitespace = .indent_4 },
    );
    defer self.allocator.free(string);
    try fs.overwrite(path, string);
}

fn addDayToStage(
    self: *Journal,
    map: *StagedEntries,
    path: []const u8,
) !void {
    var alloc = self.getTmpAllocator();
    if (self.fs) |*fs| {
        // read entries and init owned list
        var entries = try self.readDayFromPath(fs, path);
        try map.put(path, std.ArrayList(Entry).fromOwnedSlice(
            alloc,
            entries,
        ));
    } else {
        // else create empty list
        std.log.default.warn("No Filesystem in Journal", .{});
        try map.put(path, std.ArrayList(Entry).init(alloc));
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

/// Add an `Entry` to a given `Day`. Does not write to file until
/// `writeChanges` is called.
pub fn addNewEntryToDay(
    self: *Journal,
    day: Day,
    entry: Entry,
) !void {
    try self.addNewEntryToPath(day.path, entry);
}

/// Add a new entry to the appropriate day as given by the `created` timestamp
/// in the entry.
pub fn addEntry(self: *Journal, entry: Entry) !Day {
    var alloc = self.getTmpAllocator();
    // get the day this entry belongs to
    const day_name = try timeToName(alloc, entry.created);
    const day = try self.getDayOrNew(day_name);

    try self.addNewEntryToDay(day, entry);
    return day;
}

/// Add a new entry with `text` with a list of additional tags. Will also parse
/// the text for context tags and append. The additional tags should already
/// have the `@` trimmed.
pub fn addNewEntryFromText(
    self: *Journal,
    text: []const u8,
    entry_tags: []const Tag,
) !Day {
    const now = time.timeNow();
    return try self.addEntry(.{
        .text = text,
        .tags = entry_tags,
        .created = now,
        .modified = now,
    });
}

/// Write all days that have staged changes to disk
pub fn writeDays(self: *Journal) !void {
    var fs = self.fs orelse return error.NeedsFileSystem;
    var map = self.staged_entries orelse {
        std.log.default.debug("No staged entries for Journal '{s}'", .{self.descriptor.name});
        return;
    };

    var itt = map.iterator();
    while (itt.next()) |item| {
        const day_path = item.key_ptr;
        const entry_list = item.value_ptr;
        try self.writeEntriesToPath(fs, entry_list.items, day_path.*);
    }
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Journal.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Caller owns memory
pub fn serialize(self: *const Journal, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
