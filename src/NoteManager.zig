const std = @import("std");
const State = @import("State.zig");

const notes = @import("notes.zig");
const NoteInfo = notes.named_note.NoteInfo;

const _NoteManagerSchema = struct {
    note_infos: []NoteInfo,
};

pub const DATA_STORE_FILENAME = ".topology.json";

fn toJsonString(alloc: std.mem.Allocator, schema: _NoteManagerSchema) ![]const u8 {
    return std.json.stringifyAlloc(
        alloc,
        schema,
        .{ .whitespace = .indent_4 },
    );
}

fn parseNoteManager(alloc: std.mem.Allocator, string: []const u8) !_NoteManagerSchema {
    var parsed = try std.json.parseFromSliceLeaky(
        _NoteManagerSchema,
        alloc,
        string,
        .{},
    );
    return parsed;
}

const Self = @This();

note_infos: []NoteInfo,
mem: std.heap.ArenaAllocator,

pub fn init(alloc: std.mem.Allocator, fs: *State.FileSystem) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var temp_alloc = mem.allocator();

    var content = try fs.readFileAllocElseNull(temp_alloc, DATA_STORE_FILENAME);

    var note_infos = if (content) |ct|
        (try parseNoteManager(temp_alloc, ct)).note_infos
    else
        try temp_alloc.alloc(NoteInfo, 0);

    return .{
        .note_infos = note_infos,
        .mem = mem,
    };
}

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}

pub fn createInfo(self: *Self, name: []const u8) !*NoteInfo {
    var alloc = self.mem.allocator();
    var info = try NoteInfo.new(alloc, name);
    errdefer info.free(alloc);

    var list = std.ArrayList(NoteInfo).fromOwnedSlice(
        alloc,
        self.note_infos,
    );

    try list.append(info);
    self.note_infos = try list.toOwnedSlice();

    return &(self.note_infos[self.note_infos.len - 1]);
}

pub fn getOrCreatePtrInfo(self: *Self, name: []const u8) !*NoteInfo {
    return self.getPtrToInfo(name) orelse
        try self.createInfo(name);
}

pub fn writeChanges(self: *const Self, state: *State) !void {
    const string = try toJsonString(self.mem.child_allocator, .{ .note_infos = self.note_infos });
    defer self.mem.child_allocator.free(string);
    try state.fs.overwrite(DATA_STORE_FILENAME, string);
}

pub fn getPtrToInfo(self: *Self, name: []const u8) ?*NoteInfo {
    for (self.note_infos) |*info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    return null;
}
