const std = @import("std");
const utils = @import("utils.zig");
const notes = @import("notes.zig");

pub const NoteManager = @import("NoteManager.zig");
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
pub const NamedNoteMap = std.StringArrayHashMap(notes.named_note.Note);

fs: FileSystem,
mem: std.heap.ArenaAllocator,
diary: DiaryMap,
named_notes: NamedNoteMap,
manager: NoteManager,

pub const Config = struct {
    root_path: []const u8,
};

pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();

    var diarymap = DiaryMap.init(mem.child_allocator);
    errdefer diarymap.deinit();

    var namedmap = NamedNoteMap.init(mem.child_allocator);
    errdefer namedmap.deinit();

    var file_system = try FileSystem.init(config.root_path);
    errdefer file_system.deinit();

    var manager = try NoteManager.init(mem.child_allocator, &file_system);
    errdefer manager.deinit();

    return .{
        .fs = file_system,
        .mem = mem,
        .diary = diarymap,
        .named_notes = namedmap,
        .manager = manager,
    };
}

pub fn deinit(self: *Self) void {
    self.diary.deinit();
    self.named_notes.deinit();
    self.fs.deinit();
    self.manager.deinit();
    self.mem.deinit();
    self.* = undefined;
}

/// Lookup a named note in the note map, else open or create it and store
/// in the note map. Returns a pointer to the Note.
pub fn openNamedNote(self: *Self, name: []const u8) !*notes.named_note.Note {
    return self.named_notes.getPtr(name) orelse {
        var note = try notes.named_note.openOrCreate(self, name);
        try self.named_notes.put(name, note);
        return self.named_notes.getPtr(name).?;
    };
}

/// Lookup the diary entry in the diary map, else open it and store in
/// the diary map. Returns a pointer to the Entry.
pub fn openDiaryEntry(self: *Self, date: utils.Date) !*notes.diary.Entry {
    const key = toKey(date);
    return self.diary.getPtr(key) orelse {
        var entry = try notes.diary.openOrCreate(self, date);
        try self.diary.put(key, entry);
        return self.diary.getPtr(key).?;
    };
}

pub fn openToday(self: *Self) !*notes.diary.Entry {
    return self.openDiaryEntry(utils.Date.now());
}

/// Turn a path relative to the root directory into an absolute file
/// path. State owns the memory.
pub fn absPathify(self: *Self, rel_path: []const u8) ![]const u8 {
    return self.fs.absPathify(self.mem.allocator(), rel_path);
}

pub fn writeChanges(self: *Self) !void {
    try self.manager.writeChanges(self);
}
