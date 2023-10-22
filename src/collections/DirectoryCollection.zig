const std = @import("std");
const utils = @import("../utils.zig");

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const ContentMap = @import("ContentMap.zig");
const wrappers = @import("wrappers.zig");
const Ordering = wrappers.Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Note = Topology.Note;
const Directory = Topology.Directory;
const Self = @This();

pub const DEFAULT_FILE_EXTENSION = ".md";

// public interface for getting the subtypes
pub const Parent = Directory;
pub const Child = Note;

pub const DirectoryItem = struct {
    collection: *Self,
    item: Child,

    pub fn relativePath(self: DirectoryItem) []const u8 {
        return self.item.info.path;
    }
};

directory_allocator: std.mem.Allocator,
directory: *Directory,
content: ContentMap,
fs: FileSystem,
index: IndexContainer,

pub usingnamespace wrappers.Mixin(
    Self,
    *Note.Info,
    Note,
    "directory",
    "infos",
    prepareItem,
);

fn prepareItem(self: *Self, info: *Note.Info) Note {
    return .{
        .info = info,
        .content = self.content.get(info.name),
    };
}

pub const NoteList = struct {
    allocator: std.mem.Allocator,
    items: []Note,

    pub usingnamespace utils.ListMixin(NoteList, Note);

    pub fn sortBy(self: *NoteList, ordering: Ordering) void {
        const sorter = std.sort.insertion;
        switch (ordering) {
            .Created => sorter(Note, self.items, {}, Note.sortCreated),
            .Modified => sorter(Note, self.items, {}, Note.sortModified),
        }
    }
};

/// Caller owns the memory
pub fn getNoteList(
    self: *Self,
    alloc: std.mem.Allocator,
) !NoteList {
    var notes = try alloc.alloc(Note, self.directory.infos.len);
    errdefer alloc.free(notes);

    for (notes, self.directory.infos) |*note, *info| {
        note.* = .{
            .info = info,
            .content = self.content.get(info.name),
        };
    }

    return NoteList.initOwned(alloc, notes);
}

pub fn readNoteContent(self: *Self, note: *Note) !void {
    if (note.content == null) {
        note.content = try self.readContent(note.info.*);
    }
}

/// Reads note. Will return null if note does not exist. Does not
/// attempt to read the note content. Use `readNote` to attempt to
/// read content
pub fn getNote(self: *Self, name: []const u8) ?Note {
    for (self.directory.infos) |*info| {
        if (std.mem.eql(u8, info.name, name)) {
            return .{
                .info = info,
                .content = self.content.get(name),
            };
        }
    }
    return null;
}

fn readContent(self: *Self, info: Note.Info) ![]const u8 {
    var alloc = self.content.mem.allocator();
    const content = try self.fs.readFileAlloc(alloc, info.path);
    try self.content.putMove(info.name, content);
    return content;
}

pub fn readNote(self: *Self, name: []const u8) !?Note {
    var note = self.getNote(name) orelse return null;
    note.content = self.readContent(note.info.*);
    return note;
}

pub fn addNote(
    self: *Self,
    info: Note.Info,
    content: ?[]const u8,
) !Note {
    const info_ptr = try utils.push(
        Note.Info,
        self.directory_allocator,
        &self.directory.infos,
        info,
    );

    if (content) |c| {
        try self.content.put(info.name, c);
    }

    return .{
        .info = info_ptr,
        .content = self.content.get(info.name),
    };
}

fn childPath(self: *Self, name: []const u8) ![]const u8 {
    const filename = try std.mem.concat(
        self.directory_allocator,
        u8,
        &.{ name, DEFAULT_FILE_EXTENSION },
    );
    return try std.fs.path.join(
        self.directory_allocator,
        &.{ self.directory.path, filename },
    );
}

pub fn newChild(
    self: *Self,
    name: []const u8,
) !DirectoryItem {
    const owned_name = try self.directory_allocator.dupe(u8, name);

    const now = utils.now();
    const info: Note.Info = .{
        .modified = now,
        .created = now,
        .name = owned_name,
        .path = try self.childPath(owned_name),
        .tags = try utils.emptyTagList(self.directory_allocator),
    };

    var note = try self.addNote(info, null);
    return .{ .collection = self, .item = note };
}
