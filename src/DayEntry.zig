const std = @import("std");
const utils = @import("utils.zig");

const State = @import("State.zig");

pub const DAY_ENTRY_ENDING = ".md";
pub const DAY_META_ENDING = ".meta.json";

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
date: utils.Date,

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}

fn initElseNew(
    alloc: std.mem.Allocator,
    date: utils.Date,
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
        .date = date,
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

pub fn openDate(
    alloc: std.mem.Allocator,
    date: utils.Date,
    state: *State,
) !Self {
    var mem = std.heap.ArenaAllocator.init(alloc);
    defer mem.deinit();
    var temp_alloc = mem.allocator();

    const entry_path = try entryPath(temp_alloc, date, state);
    const meta_path = try metaPath(temp_alloc, date, state);

    return Self.initElseNew(alloc, date, entry_path, meta_path, state);
}

pub fn today(
    alloc: std.mem.Allocator,
    state: *State,
) !Self {
    const date = utils.Date.now();
    return openDate(alloc, date, state);
}

pub fn entryPath(alloc: std.mem.Allocator, date: utils.Date, _: *State) ![]u8 {
    const date_string = try utils.formatDateBuf(date);
    var entry = try std.mem.concat(alloc, u8, &.{ &date_string, DAY_ENTRY_ENDING });
    defer alloc.free(entry);

    return std.fs.path.join(alloc, &.{ State.LOG_DIRECTORY, entry });
}

pub fn metaPath(alloc: std.mem.Allocator, date: utils.Date, _: *State) ![]u8 {
    const date_string = try utils.formatDateBuf(date);
    var meta = try std.mem.concat(alloc, u8, &.{ &date_string, DAY_META_ENDING });
    defer alloc.free(meta);

    return std.fs.path.join(alloc, &.{ State.LOG_DIRECTORY, meta });
}

pub fn entryPathElseTemplate(alloc: std.mem.Allocator, date: utils.Date, state: *State) ![]u8 {
    var entry_path = try entryPath(alloc, date, state);
    errdefer alloc.free(entry_path);

    const file_exists = try state.fileExists(entry_path);
    if (!file_exists) {
        var dir = try state.getDir();
        var fs = try dir.createFile(entry_path, .{});
        defer fs.close();

        var writer = fs.writer();

        var day_of_week = try utils.dayOfWeek(alloc, date);
        defer alloc.free(day_of_week);

        var month_of_year = try utils.monthOfYear(alloc, date);
        defer alloc.free(month_of_year);

        try writer.print(
            "# {s} - {s} of {s}\n\n",
            .{
                try utils.formatDateBuf(date),
                day_of_week,
                month_of_year,
            },
        );
    }
    return entry_path;
}

pub const DayList = struct {
    alloc: std.mem.Allocator,
    days: []utils.Date,

    pub fn deinit(self: *DayList) void {
        self.alloc.free(self.days);
        self.* = undefined;
    }

    pub fn sort(self: *DayList) void {
        std.sort.insertion(utils.Date, self.days, {}, utils.dateSort);
    }
};

pub fn getDayList(alloc: std.mem.Allocator, state: *State) !DayList {
    var log_dir = try state.iterableLogDirectory();
    defer log_dir.close();

    var list = std.ArrayList(utils.Date).init(alloc);
    errdefer list.deinit();

    var itt = log_dir.iterate();
    while (try itt.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, DAY_META_ENDING)) |end| {
            const day = entry.name[0..end];
            const date = utils.toDate(day) catch continue;
            try list.append(date);
        }
    }

    return .{ .alloc = alloc, .days = try list.toOwnedSlice() };
}
