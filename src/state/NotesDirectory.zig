const std = @import("std");
const utils = @import("../utils.zig");

const Topology = @import("../Topology.zig");
const FileSystem = @import("../FileSystem.zig");

const ContentMap = @import("ContentMap.zig");
const Ordering = @import("collections.zig").Ordering;

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Self = @This();

directory_allocator: std.mem.Allocator,
directory: *Topology.Directory,
content: ContentMap,
fs: FileSystem,
index: IndexContainer,

const Note = Topology.Note;

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
    self.content.putMove(info.name, content);
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
) !void {
    utils.push(Note.Info, self.directory_allocator, self.directory.infos, info);
    if (content) |c| {
        try self.content.put(info.name, c);
    }
}
