const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const Commands = @import("../main.zig").Commands;
const State = @import("../NewState.zig");

const Self = @This();

pub const ListError = error{CannotListJournal};

pub const alias = [_][]const u8{"ls"};

pub const help = "List notes in various ways.";
pub const extended_help =
    \\List notes in various ways to the terminal.
    \\  nkt list
    \\     [what]                list journals, directories, or notes with a
    \\                             `directory` to list. this option may also be
    \\                             `all` to list everything (default: all)
    \\     [-n/--limit int]      maximum number of entries to list (default: 25)
    \\     [--all]               list all entries (ignores `--limit`)
    \\     [--modified]          sort by last modified (default)
    \\     [--created]           sort by date created
    \\
;

selection: []const u8,
ordering: State.Ordering,
number: usize,
all: bool,

pub fn init(itt: *cli.ArgIterator) !Self {
    var self: Self = .{
        .selection = "",
        .ordering = .Modified,
        .number = 25,
        .all = false,
    };

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "limit")) {
                const value = try itt.getValue();
                self.number = try value.as(usize);
            } else if (arg.is(null, "all")) {
                self.all = true;
            } else if (arg.is(null, "modified")) {
                self.ordering = .Modified;
            } else if (arg.is(null, "created")) {
                self.ordering = .Created;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (self.selection.len == 0) {
                self.selection = arg.string;
            } else return cli.CLIErrors.TooManyArguments;
        }
    }

    if (self.selection.len == 0) self.selection = "all";

    return self;
}

fn listDirectory(
    self: *Self,
    alloc: std.mem.Allocator,
    directory: *State.NotesDirectory,
    writer: anytype,
) !void {
    var notelist = try directory.getNoteList(alloc);
    defer notelist.deinit();

    notelist.sortBy(self.ordering);

    switch (self.ordering) {
        .Modified => try writer.print(
            "Directory '{s}' ordered by last modified:\n",
            .{directory.directory.name},
        ),
        .Created => try writer.print(
            "Directory '{s}' ordered by date created:\n",
            .{directory.directory.name},
        ),
    }

    const is_diary = std.mem.eql(u8, "diary", directory.directory.name);
    for (notelist.items) |note| {
        if (is_diary) {
            try writer.print("{s}\n", .{note.info.name});
        } else {
            const date = switch (self.ordering) {
                .Modified => utils.Date.initUnixMs(note.info.modified),
                .Created => utils.Date.initUnixMs(note.info.created),
            };
            const date_string = try utils.formatDateBuf(date);
            try writer.print("{s} - {s}\n", .{ date_string, note.info.name });
        }
    }
}

fn listNames(
    _: *const Self,
    cnames: State.CollectionNameList,
    what: State.CollectionTypes,
    writer: anytype,
) !void {
    switch (what) {
        .Directory => try writer.print("Directories list:\n", .{}),
        .Journal => try writer.print("Journals list:\n", .{}),
    }

    for (cnames.items) |name| {
        if (name.collection == what) {
            try writer.print(" {s}\n", .{name.name});
        }
    }
}

fn is(s: []const u8, other: []const u8) bool {
    return std.mem.eql(u8, s, other);
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    if (is(self.selection, "all")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try self.listNames(cnames, .Directory, out_writer);
        try self.listNames(cnames, .Journal, out_writer);
    } else if (is(self.selection, "directories") or is(self.selection, "dirs")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try self.listNames(cnames, .Directory, out_writer);
    } else if (is(self.selection, "journals") or is(self.selection, "jrnl")) {
        var cnames = try state.getCollectionNames(state.allocator);
        defer cnames.deinit();

        try self.listNames(cnames, .Journal, out_writer);
    } else {
        var collection = try state.getCollection(self.selection);
        switch (collection) {
            .Directory => |d| {
                try self.listDirectory(state.allocator, d, out_writer);
            },
            .Journal => return ListError.CannotListJournal,
        }
    }
}
