const std = @import("std");
const tags = @import("tags.zig");
const Tag = tags.Tag;
const Time = @import("time.zig").Time;
const FileSystem = @import("../FileSystem.zig");

const Directory = @This();

pub const TOPOLOGY_FILENAME = "topology.json";
pub const PATH_PREFIX = "dir";

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
fs: ?FileSystem = null,
allocator: std.mem.Allocator,

pub fn deinit(self: *Directory) void {
    self.allocator.free(self.info.tags);
    self.allocator.free(self.info.notes);
    self.* = undefined;
}

/// Add a new day to the journal. No strings are copied, so it is
/// assumed the contents of the `day` will outlive the `Directory`.
pub fn addNewNote(self: *Directory, note: Note) !void {
    var list = std.ArrayList(Note).fromOwnedSlice(
        self.allocator,
        self.info.notes,
    );
    try list.append(note);
    self.info.notes = try list.toOwnedSlice();
}

/// Serialize into a string for writing to file.
/// Caller owns the memory.
pub fn defaultSerialize(allocator: std.mem.Allocator) ![]const u8 {
    const default: Directory.Info = .{};
    return try serializeInfo(default, allocator);
}

/// Caller owns memory
pub fn serialize(self: *Directory, allocator: std.mem.Allocator) ![]const u8 {
    return try serializeInfo(self.info.*, allocator);
}

fn serializeInfo(info: Info, allocator: std.mem.Allocator) ![]const u8 {
    return try std.json.stringifyAlloc(
        allocator,
        info,
        .{ .whitespace = .indent_4 },
    );
}
