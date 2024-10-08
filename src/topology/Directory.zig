const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const time = @import("time.zig");
const Time = time.Time;
const Root = @import("Root.zig");
const FileSystem = @import("../FileSystem.zig");
const Descriptor = @import("Root.zig").Descriptor;

const Selector = @import("../selections.zig").Selector;
const SelectionConfig = @import("../selections.zig").SelectionConfig;

const Directory = @This();

pub const TOPOLOGY_FILENAME = "topology.json";
pub const PATH_PREFIX = "dir";

pub const Error = error{ DuplicateNote, NoSuchNote };

pub const Note = struct {
    name: []const u8,
    path: []const u8,
    created: Time,
    modified: Time,
    tags: []Tag,

    /// Get the file extension of the note
    pub fn getExtension(n: Note) []const u8 {
        const ext = std.fs.path.extension(n.path);
        if (ext[0] == '.') return ext[1..];
        return ext;
    }

    pub fn sortAlphabetical(_: void, lhs: Note, rhs: Note) bool {
        return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
    }

    pub fn sortCreated(_: void, lhs: Note, rhs: Note) bool {
        return lhs.created.time < rhs.created.time;
    }

    pub fn sortModified(_: void, lhs: Note, rhs: Note) bool {
        return lhs.modified.time < rhs.modified.time;
    }
};

pub const Info = struct {
    notes: []Note = &.{},
    tags: []Tag = &.{},
};

/// Get a pointer to the info struct
pub inline fn getInfo(self: *const Directory) *Info {
    return &self.root.cache.directories.getPtr(
        self.id,
    ).?.item;
}
/// Get the FileSystem
pub inline fn getFS(self: *const Directory) ?FileSystem {
    return self.root.fs;
}
/// Get a pointer to the FileSystem
pub inline fn getTagList(self: *const Directory) ?*tags.DescriptorList {
    return self.root.tag_descriptors;
}

root: *Root,
descriptor: Descriptor,
// an ephemeral allocator
allocator: std.mem.Allocator,
id: u64,

/// Add a new day to the journal. No strings are copied, so it is
/// assumed the contents of the `day` will outlive the `Directory`.
/// If a `FileSystem` is given, will create an empty file if none exists.
pub fn addNewNote(self: *Directory, note: Note) !void {
    const info = self.getInfo();
    var list = std.ArrayList(Note).fromOwnedSlice(
        self.allocator,
        info.notes,
    );
    try list.append(note);
    info.notes = try list.toOwnedSlice();

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

    const now = time.Time.now();
    const note: Note = .{
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
    const alloc = self.allocator;
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
    const note_ptr = self.getNotePtr(name) orelse return null;
    return note_ptr.*;
}

/// Get pointer to the note by name. Returns `null` if no such note is in the
/// directory.
pub fn getNotePtr(self: *const Directory, name: []const u8) ?*Note {
    const info = self.getInfo();
    for (info.notes) |*n| {
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
    var fs = self.getFS() orelse return error.NeedsFileSystem;
    return try fs.readFileAlloc(allocator, note.path);
}

/// Update the note by name with a new note descriptor
pub fn updateNote(self: *Directory, name: []const u8, new: Note) !Note {
    // TODO: maybe make copies of the slices?
    // TODO: store the note index with the note on retrieval so we don't have
    // to do this lookup twice, else even just hand around the pointer?
    const note_ptr = self.getNotePtr(name) orelse return Error.NoSuchNote;
    note_ptr.* = new;
    return note_ptr.*;
}

/// Rename and move files associated with the Note at `old_name` to `new_name`.
pub fn rename(
    self: *Directory,
    old_name: []const u8,
    new_name: []const u8,
) !Note {
    var fs = self.getFS() orelse return error.NeedsFileSystem;

    var ptr = self.getNotePtr(old_name) orelse
        return Error.NoSuchNote;

    const old_path = ptr.path;
    const new_path = try self.newPathFromName(
        new_name,
        std.fs.path.extension(old_path)[1..],
    );

    ptr.name = new_name;
    ptr.path = new_path;
    ptr.modified = time.Time.now();

    try fs.move(old_path, new_path);
    return ptr.*;
}

/// Add new tags to a `Note`
pub fn addTagsToNote(self: *const Directory, note: Note, ts: []const tags.Tag) !void {
    const ptr = self.getNotePtr(note.name).?;
    ptr.tags = try tags.setUnion(self.allocator, ptr.tags, ts);
}

/// Remove tags from a `Note`
pub fn removeTagsFromNote(self: *const Directory, note: Note, ts: []const tags.Tag) !void {
    const ptr = self.getNotePtr(note.name).?;
    ptr.tags = try tags.remove(self.allocator, ptr.tags, ts);
}

/// Update the modified time of a note
pub fn touchNote(self: *Directory, note: Note, t: time.Time) !Note {
    var new = note;
    new.modified = t;
    return try self.updateNote(note.name, new);
}

/// Remove a note from the directory. Will attempt to remove the associated file in the filesystem.
pub fn removeNote(self: *Directory, note: Note) !void {
    const info = self.getInfo();
    var list = std.ArrayList(Note).fromOwnedSlice(
        self.allocator,
        info.notes,
    );

    const index = b: {
        for (list.items, 0..) |n, i| {
            if (n.created.eql(note.created)) {
                break :b i;
            }
        }
        return Error.NoSuchNote;
    };

    _ = list.orderedRemove(index);
    info.notes = try list.toOwnedSlice();

    // try and remove associated file
    var fs = self.getFS() orelse {
        std.log.default.debug("Cannot remove day file as no file system", .{});
        return;
    };
    try fs.removeFile(note.path);
}

/// Caller owns memory
pub fn serialize(self: *const Directory, allocator: std.mem.Allocator) ![]const u8 {
    const info = self.getInfo();
    return try serializeInfo(info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}

/// Used to retrieve specific items from a journal
pub fn select(self: *Directory, selector: Selector, config: SelectionConfig) !Note {
    try config.noModifiers();
    const name: []const u8 = switch (selector) {
        .ByName => |n| n,
        .ByDate => |d| &(try time.formatDateBuf(d)),
        else => return error.InvalidSelection,
    };
    return self.getNote(name) orelse
        return error.NoSuchItem;
}
