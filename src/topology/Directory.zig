const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const time = @import("time.zig");
const Time = time.Time;
const FileSystem = @import("../FileSystem.zig");
const Descriptor = @import("Root.zig").Descriptor;

const Directory = @This();

pub const TOPOLOGY_FILENAME = "topology.json";
pub const PATH_PREFIX = "dir";

pub const Error = error{DuplicateNote};

pub const Note = struct {
    name: []const u8,
    path: []const u8,
    created: Time,
    modified: Time,
    tags: []Tag,
};

pub const Info = struct {
    notes: []Note = &.{},
    tags: []Tag = &.{},
};

info: *Info,
descriptor: Descriptor,
allocator: std.mem.Allocator,
fs: ?FileSystem = null,
mem: ?std.heap.ArenaAllocator = null,

fn getTmpAllocator(self: *Directory) std.mem.Allocator {
    if (self.mem == null) {
        self.mem = std.heap.ArenaAllocator.init(self.allocator);
    }
    return self.mem.?.allocator();
}

pub fn deinit(self: *Directory) void {
    if (self.mem) |*mem| mem.deinit();
    self.* = undefined;
}

/// Add a new day to the journal. No strings are copied, so it is
/// assumed the contents of the `day` will outlive the `Directory`.
/// If a `FileSystem` is given, will create an empty file if none exists.
pub fn addNewNote(self: *Directory, note: Note) !void {
    var list = std.ArrayList(Note).fromOwnedSlice(
        self.getTmpAllocator(),
        self.info.notes,
    );
    try list.append(note);
    self.info.notes = try list.toOwnedSlice();

    // TODO: touch the file
}

pub const NewNoteOptions = struct {
    extension: []const u8 = "md",
};

/// Adds a new note with `name` to the directory. Asserts no other note by the
/// same name in this directory exists.
/// Returns the `Note`.
/// If a `FileSystem` is given, will create an empty file if none exists.
pub fn addNewNoteByName(
    self: *Directory,
    name: []const u8,
    opts: NewNoteOptions,
) !Note {
    if (self.getNote(name)) |_| return Error.DuplicateNote;

    const now = time.timeNow();
    var note: Note = .{
        .name = name,
        .path = try self.newPathFromName(name, opts.extension),
        .created = now,
        .modified = now,
        .tags = &.{},
    };

    try self.addNewNote(note);
    return note;
}

fn newPathFromName(
    self: *Directory,
    name: []const u8,
    extension: []const u8,
) ![]const u8 {
    const dirname = std.fs.path.dirname(self.descriptor.path).?;
    var alloc = self.getTmpAllocator();
    return std.fs.path.join(
        alloc,
        &.{ dirname, try std.mem.join(
            alloc,
            ".",
            &.{ name, extension },
        ) },
    );
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Directory.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Get the note by name. Returns `null` if no such note is in the directory.
pub fn getNote(self: *const Directory, name: []const u8) ?Note {
    for (self.info.notes) |n| {
        if (std.mem.eql(u8, n.name, name)) return n;
    }
    return null;
}

/// Read a note from file. Returns the note contens. Caller owns the memory.
pub fn readNote(
    self: *Directory,
    allocator: std.mem.Allocator,
    note: Note,
) ![]const u8 {
    var fs = self.fs orelse return error.NeedsFileSystem;
    return try fs.readFileAlloc(allocator, note.path);
}

/// Caller owns memory
pub fn serialize(self: *const Directory, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
