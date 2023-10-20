// the actual textual entry will be a markdown file, and additional links /
// notes will be stored in a json. The json file can also store various meta
// data associated with that day, such as number of tasks completed etc.
//     yyyy-mm-dd.entry.md
//     yyyy-mm-dd.meta.json
// all time and timezone information will always be stored in UTC
// and converted as needed

// when user edits a given day's entry, EDITOR is used
// to edit the metadata, CLI is used to modify specific parts
// with an option for the user to pop open the json file in EDITOR
// if absolutely needed

const std = @import("std");
const utils = @import("../utils.zig");
const State = @import("../State.zig");

pub const DIARY_ENTRY_SUFFIX = ".md";
pub const DIARY_EXTRA_SUFFIX = ".meta.json";

fn relativePath(state: *State, date: utils.Date, suffix: []const u8) ![]const u8 {
    var alloc = state.mem.allocator();
    const date_string = try utils.formatDateBuf(date);
    var entry = try std.mem.concat(
        alloc,
        u8,
        &.{ &date_string, suffix },
    );
    defer alloc.free(entry);

    return std.fs.path.join(alloc, &.{ State.FileSystem.DIARY_DIRECTORY, entry });
}

/// Get the relative path to the diary entry.
/// State owns the memory.
pub fn diaryPath(state: *State, date: utils.Date) ![]const u8 {
    return relativePath(state, date, DIARY_ENTRY_SUFFIX);
}

/// Get the relative path to the notes entry.
/// State owns the memory.
pub fn notesPath(state: *State, date: utils.Date) ![]const u8 {
    return relativePath(state, date, DIARY_EXTRA_SUFFIX);
}

pub const DiaryNote = struct {
    created: u64,
    modified: u64,
    content: []u8,
};

pub const Entry = struct {
    alloc: std.mem.Allocator,

    date: utils.Date,

    diary_path: []const u8,
    notes_path: []const u8,

    notes: []DiaryNote,
    content: ?[]u8 = null,

    has_diary: bool = false,

    /// Insert a new note at the end of the diary's notes list.
    pub fn addNote(self: *Entry, content: []const u8) !void {
        const owned_content = try self.alloc.dupe(u8, content);
        errdefer self.alloc.free(owned_content);

        const now = utils.now();
        const note: DiaryNote = .{
            .content = owned_content,
            .created = now,
            .modified = now,
        };

        var list = std.ArrayList(DiaryNote).fromOwnedSlice(
            self.alloc,
            self.notes,
        );

        try list.append(note);
        self.notes = try list.toOwnedSlice();
    }

    /// Read the contents of the diary entry and return slice.
    /// Will not check if file exists and will raise error if not.
    /// Entry owns the memory.
    pub fn readDiary(self: *Entry, state: *const State) ![]const u8 {
        if (self.content) |ct| return ct;
        self.content = try state.fs.readFileAlloc(self.alloc, self.diary_path);
        return self.content.?;
    }

    pub fn deinit(self: *Entry) void {
        for (self.notes) |note| self.alloc.free(note.content);
        self.alloc.free(self.notes);
        self.* = undefined;
    }

    pub fn writeNotes(self: *Entry, state: *const State) !void {
        var fs = try state.fs.openElseCreate(self.notes_path);
        defer fs.close();

        const string = try toJsonString(self.alloc, self.notes);
        defer self.alloc.free(string);

        // seek to start to remove anything that may already be in the file
        try fs.seekTo(0);
        try fs.writeAll(string);
        try fs.setEndPos(string.len);
    }
};

const _DiaryNoteSchema = struct { notes: []DiaryNote };

fn toJsonString(alloc: std.mem.Allocator, notes: []DiaryNote) ![]const u8 {
    return std.json.stringifyAlloc(
        alloc,
        _DiaryNoteSchema{ .notes = notes },
        .{ .whitespace = .indent_4 },
    );
}

fn parseNotes(alloc: std.mem.Allocator, string: []const u8) ![]DiaryNote {
    var parsed = try std.json.parseFromSliceLeaky(
        _DiaryNoteSchema,
        alloc,
        string,
        .{},
    );
    return parsed.notes;
}

/// Open the diary entry from a specified date.
/// Will create a blank entry if entry does not exist.
pub fn openOrCreate(state: *State, date: utils.Date) !Entry {
    var alloc = state.mem.allocator();

    const diary_path = try diaryPath(state, date);
    const notes_path = try notesPath(state, date);

    var notes_content = try state.fs.readFileAllocElseNull(
        state.mem.child_allocator,
        notes_path,
    );
    defer if (notes_content) |ct| state.mem.child_allocator.free(ct);

    var notes: []DiaryNote = if (notes_content) |ct|
        try parseNotes(alloc, ct)
    else
        try alloc.alloc(DiaryNote, 0);

    const has_diary = try state.fs.fileExists(diary_path);

    return .{
        .alloc = alloc,
        .date = date,
        .diary_path = diary_path,
        .notes_path = notes_path,
        .notes = notes,
        .has_diary = has_diary,
    };
}
