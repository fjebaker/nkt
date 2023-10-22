const std = @import("std");

const utils = @import("../utils.zig");
const cli = @import("../cli.zig");

const State = @import("../State.zig");
const Item = State.Item;

const CollectionType = State.CollectionType;
const Date = utils.Date;

fn isNumeric(c: u8) bool {
    return (c >= '0' and c <= '9');
}

fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c)) return false;
    }
    return true;
}

fn isDate(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c) and c != '-') return false;
    }
    return true;
}

pub const SelectedCollection = struct {
    container: CollectionType,
    name: []const u8,

    pub fn from(container: CollectionType, name: []const u8) SelectedCollection {
        return .{
            .container = container,
            .name = name,
        };
    }
};

pub const SelectionSet = enum {
    ByIndex,
    ByDate,
    ByName,
};

pub const Selection = union(enum) {
    ByIndex: usize,
    ByDate: Date,
    ByName: []const u8,

    pub fn today() Selection {
        const date = Date.now();
        return .{ .ByDate = date };
    }

    /// Parse input string into a Selection. Does not validate that the
    /// selection exists.
    pub fn parse(input: []const u8) !Selection {
        if (std.mem.eql(u8, input, "today") or std.mem.eql(u8, input, "t")) {
            return Selection.today();
        } else if (allNumeric(input)) {
            const day = try std.fmt.parseInt(usize, input, 10);
            return .{ .ByIndex = day };
        } else if (isDate(input)) {
            const date = try utils.toDate(input);
            return .{ .ByDate = date };
        } else {
            return .{ .ByName = input };
        }
    }

    /// Parse ArgIterator into a Selection. Does not validate that the
    /// selection exists. If no positional argument is available, returns null,
    /// allowing caller to set defaults.
    pub fn optionalParse(
        itt: *cli.ArgIterator,
    ) !?Selection {
        const arg = (try itt.next()) orelse return null;
        if (arg.flag) {
            itt.rewind();
            return null;
        }
        return try parse(arg.string);
    }
};

fn finalize(maybe_note: ?Item, maybe_journal: ?Item) ?Item {
    if (maybe_note != null and maybe_journal != null) {
        return .{
            .DirectoryJournalItems = .{
                .journal = maybe_journal.?.JournalEntry,
                .directory = maybe_note.?.Note,
            },
        };
    }
    return maybe_note orelse
        maybe_journal orelse
        null;
}

fn finalizeMatching(state: *State, journal: Item) ?Item {
    const journal_name = journal.JournalEntry.collection.journal.name;
    const dir = state.getDirectory(journal_name) orelse
        return journal;

    const entry_name = journal.JournalEntry.item.name;
    if (dir.get(entry_name)) |item| {
        return finalize(
            .{ .Note = .{ .collection = dir, .item = item } },
            journal,
        );
    }
    return journal;
}

/// Search in the user preferred order
fn findIndexPreferredJournal(state: *State, index: usize) ?Item {
    if (state.getJournal("diary")) |journal| {
        if (journal.getIndex(index)) |entry| {
            return .{ .JournalEntry = .{ .collection = journal, .item = entry } };
        }
    }
    const journal: ?Item = for (state.journals) |*journal| {
        if (journal.getIndex(index)) |item| {
            break .{ .JournalEntry = .{ .collection = journal, .item = item } };
        }
    } else null;
    return journal;
}

pub fn find(state: *State, where: ?SelectedCollection, what: Selection) ?Item {
    if (where) |w| switch (w.container) {
        .Journal => {
            var journal = state.getJournal(w.name) orelse return null;
            const entry = switch (what) {
                .ByName => |name| journal.get(name),
                .ByIndex => |index| journal.getIndex(index),
                .ByDate => |date| blk: {
                    const name = utils.formatDateBuf(date) catch return null;
                    break :blk journal.get(&name);
                },
            } orelse return null;
            return .{ .JournalEntry = .{ .collection = journal, .item = entry } };
        },
        .Directory => {
            var dir = state.getDirectory(w.name) orelse return null;
            const item = switch (what) {
                .ByName => |name| dir.get(name),
                .ByIndex => |index| dir.getIndex(index),
                .ByDate => unreachable,
            } orelse return null;
            return .{ .Note = .{ .collection = dir, .item = item } };
        },
        .DirectoryWithJournal => unreachable,
    };

    // don't know if journal or entry, so we try both
    switch (what) {
        .ByName => |name| {
            return whatFromName(state, name);
        },
        // for index, we only look at journals, but use the name to do a dir lookup
        // with the condition that the directory must have the same name as the journal
        .ByIndex => |index| {
            const maybe_journal = findIndexPreferredJournal(state, index);
            if (maybe_journal) |journal| {
                return finalizeMatching(state, journal);
            } else return null;
        },
        .ByDate => |date| {
            const name = utils.formatDateBuf(date) catch return null;
            return whatFromName(state, &name);
        },
    }
    return null;
}

fn whatFromName(state: *State, name: []const u8) ?Item {
    const maybe_note: ?Item = for (state.directories) |*dir| {
        if (dir.get(name)) |item| {
            break .{ .Note = .{ .collection = dir, .item = item } };
        }
    } else null;

    const maybe_journal: ?Item = for (state.journals) |*journal| {
        if (journal.get(name)) |item| {
            break .{ .JournalEntry = .{ .collection = journal, .item = item } };
        }
    } else null;

    return finalize(maybe_note, maybe_journal);
}
