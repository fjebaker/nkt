const std = @import("std");
const utils = @import("utils.zig");

const State = @import("State.zig");

const Self = @This();

// Each day is a file
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

// Note entry that is stored in the metadata.
pub const Note = struct {
    created: u64,
    modified: u64,
    content: []u8,
};

/// Metadata for a given day's entry. Used to parse the JSON schema.
pub const Meta = struct {
    notes: []Note,

    pub fn init(mem: *std.heap.ArenaAllocator, string: []const u8) !Meta {
        var parsed = try std.json.parseFromSliceLeaky(
            Meta,
            mem.allocator(),
            string,
            .{},
        );
        return parsed;
    }

    pub fn toString(self: Meta, alloc: std.mem.Allocator) ![]const u8 {
        return std.json.stringifyAlloc(alloc, self, .{ .whitespace = .indent_4 });
    }
};

entry_filepath: []u8,
meta_filepath: []u8,
mem: std.heap.ArenaAllocator,
state: *State,
// parsed from metadata json
notes: []Note,

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}

pub fn initElseNew(
    alloc: std.mem.Allocator,
    entry_filepath: []const u8,
    meta_filepath: []const u8,
    state: *State,
) !Self {
    var meta_content = try state.readFileElseNull(alloc, meta_filepath);
    defer if (meta_content) |content| alloc.free(content);

    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();
    var mem_alloc = mem.allocator();

    var notes: []Note = if (meta_content) |content| blk: {
        std.debug.print("'{s}'\n", .{content});
        const meta = try Meta.init(&mem, content);
        break :blk meta.notes;
    } else try mem_alloc.alloc(Note, 0);

    var entry_copy = try mem_alloc.dupe(u8, entry_filepath);
    var meta_copy = try mem_alloc.dupe(u8, meta_filepath);

    return .{
        .entry_filepath = entry_copy,
        .meta_filepath = meta_copy,
        .notes = notes,
        .mem = mem,
        .state = state,
    };
}

pub fn writeAll(self: *Self) !void {
    self.writeMeta();
}

pub fn addNote(self: *Self, content: []const u8) !void {
    const now = utils.now();
    var alloc = self.mem.allocator();

    var note: Note = .{
        .content = try alloc.dupe(u8, content),
        .created = now,
        .modified = now,
    };

    var list = std.ArrayList(Note).fromOwnedSlice(alloc, self.notes);
    try list.append(note);
    self.notes = try list.toOwnedSlice();
}

pub fn writeMeta(self: *Self) !void {
    var file = try self.state.openElseCreate(self.meta_filepath);
    defer file.close();

    var alloc = self.mem.child_allocator;
    var string = try Meta.toString(.{ .notes = self.notes }, alloc);
    defer alloc.free(string);

    // seek to start to remove anything that may already be in the file
    try file.seekTo(0);
    try file.writeAll(string);
    try file.setEndPos(string.len);
}

pub fn today(
    alloc: std.mem.Allocator,
    state: *State,
) !Self {
    return Self.initElseNew(alloc, "today.md", "today.meta.json", state);
}
