const std = @import("std");
const utils = @import("utils.zig");
const State = @import("State.zig");

const notes = @import("notes.zig");
const NoteInfo = notes.named_note.NoteInfo;
const Note = notes.named_note.Note;

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

note_list: []Note,
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

    var note_list = try temp_alloc.alloc(Note, note_infos.len);
    for (0.., note_infos) |i, *info| {
        note_list[i] = Note.new(info);
    }

    return .{
        .note_list = note_list,
        .note_infos = note_infos,
        .mem = mem,
    };
}

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}

fn createInfo(self: *Self, name: []const u8) !*NoteInfo {
    var alloc = self.mem.allocator();
    var info = try NoteInfo.new(alloc, name);
    errdefer info.free(alloc);

    try utils.push(NoteInfo, alloc, &self.note_infos, info);
    return &(self.note_infos[self.note_infos.len - 1]);
}

pub fn createNote(self: *Self, name: []const u8) !*Note {
    var alloc = self.mem.allocator();

    var info = try self.createInfo(name);
    errdefer self.note_infos = self.note_infos[0 .. self.note_infos.len - 1];

    var note = Note.new(info);

    try utils.push(Note, alloc, &self.note_list, note);
    return &(self.note_list[self.note_list.len - 1]);
}

pub fn getOrCreatePtrNote(self: *Self, name: []const u8) !*Note {
    return self.getPtrToNote(name) orelse
        try self.createNote(name);
}

pub fn writeChanges(self: *const Self, state: *State) !void {
    const string = try toJsonString(self.mem.child_allocator, .{ .note_infos = self.note_infos });
    defer self.mem.child_allocator.free(string);
    try state.fs.overwrite(DATA_STORE_FILENAME, string);
}

pub fn getPtrToNote(self: *Self, name: []const u8) ?*Note {
    for (self.note_list) |*note| {
        if (std.mem.eql(u8, note.info.name, name)) return note;
    }
    return null;
}
