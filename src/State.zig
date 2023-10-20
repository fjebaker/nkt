const std = @import("std");
const utils = @import("utils.zig");
const notes = @import("notes.zig");

pub const FileSystem = @import("FileSystem.zig");

const Self = @This();

pub const DiaryMapKey = struct {
    year: u16,
    month: u16,
    day: u16,
};

fn toKey(date: utils.Date) DiaryMapKey {
    return .{
        .year = date.years,
        .month = date.months,
        .day = date.days,
    };
}
fn toDate(key: DiaryMapKey) utils.Date {
    return utils.newDate(key.year, key.month, key.day);
}

pub const DiaryMap = std.AutoHashMap(DiaryMapKey, notes.diary.Entry);

fs: FileSystem,
mem: std.heap.ArenaAllocator,
diary: DiaryMap,

pub const Config = struct {
    root_path: []const u8,
};

pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();

    var diarymap = DiaryMap.init(mem.child_allocator);
    errdefer diarymap.deinit();

    var file_system = try FileSystem.init(config.root_path);
    return .{
        .fs = file_system,
        .mem = mem,
        .diary = diarymap,
    };
}

pub fn deinit(self: *Self) void {
    self.diary.deinit();
    self.fs.deinit();
    self.mem.deinit();
    self.* = undefined;
}

/// Lookup the diary entry in the diary map, else open it and store in
/// the diary map. Returns a pointer to the Entry.
pub fn openEntry(self: *Self, date: utils.Date) !*notes.diary.Entry {
    const key = toKey(date);
    return self.diary.getPtr(key) orelse {
        var entry = try notes.diary.openEntry(self, date);
        try self.diary.put(key, entry);
        return self.diary.getPtr(key).?;
    };
}

pub fn openToday(self: *Self) !*notes.diary.Entry {
    return self.openEntry(utils.Date.now());
}

/// Turn a path relative to the root directory into an absolute file
/// path. State owns the memory.
pub fn absPathify(self: *Self, rel_path: []const u8) ![]const u8 {
    return self.fs.absPathify(self.mem.allocator(), rel_path);
}
