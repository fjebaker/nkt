const std = @import("std");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

pub const DEFAULT_FILE_EXTENSION = ".md";

fn relativePath(alloc: std.mem.Allocator, name: []const u8, suffix: []const u8) ![]const u8 {
    const filename = try std.mem.concat(
        alloc,
        u8,
        &.{ name, suffix },
    );
    defer alloc.free(filename);

    return std.fs.path.join(alloc, &.{ State.FileSystem.NOTES_DIRECTORY, filename });
}

pub const NoteInfo = struct {
    created: u64,
    modified: u64,
    name: []const u8,
    note_path: []const u8,

    pub fn new(alloc: std.mem.Allocator, name: []const u8) !NoteInfo {
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);

        const path = try relativePath(alloc, name, DEFAULT_FILE_EXTENSION);
        const now = utils.now();

        return .{
            .created = now,
            .modified = now,
            .note_path = path,
            .name = name,
        };
    }

    pub fn free(self: *NoteInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.note_path);
        self.* = undefined;
    }
};

pub const Note = struct {
    alloc: std.mem.Allocator,

    info: NoteInfo,
    content: ?[]const u8,

    /// Read the contents of the note entry and return slice.
    /// Will not check if file exists and will raise error if not.
    /// Note owns the memory.
    pub fn readNote(self: *Note, state: *State) ![]const u8 {
        if (self.content) |ct| return ct;
        self.content = try state.fs.readFileAlloc(self.alloc, self.diary_path);
        return self.content.?;
    }

    pub fn writeChanges(self: *Note, state: *State) !void {
        _ = self;
        _ = state;
    }

    pub fn deinit(self: *Note) void {
        if (self.content) |ct| self.alloc.free(ct);
        self.info.free(self.alloc);
        self.* = undefined;
    }
};

pub fn openOrCreate(state: *State, name: []const u8) !Note {
    var alloc = state.mem.allocator();

    var info = try NoteInfo.new(alloc, name);
    errdefer info.free(alloc);

    return .{
        .alloc = alloc,
        .info = info,
        .content = null,
    };
}
