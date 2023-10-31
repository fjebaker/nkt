const std = @import("std");

const utils = @import("../utils.zig");
const cli = @import("../cli.zig");

const State = @import("../State.zig");
const Item = State.Item;

const CollectionType = State.CollectionType;
const Date = utils.Date;

pub fn isNumeric(c: u8) bool {
    return (c >= '0' and c <= '9');
}

pub fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c)) return false;
    }
    return true;
}

pub fn isDate(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c) and c != '-') return false;
    }
    return true;
}

pub fn isTime(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c) and c != ':') return false;
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

/// Search in the user preferred order
fn findIndexPreferredJournal(state: *State, index: usize) ?Item {
    var p_journal: ?*State.Collection = state.getJournal("diary");

    if (p_journal) |j| {
        return j.Journal.getIndex(index);
    }

    // else search all other journals
    for (state.journals) |*j| {
        if (j.Journal.getIndex(index)) |day|
            return day;
    }
    return null;
}

pub fn find(state: *State, where: ?SelectedCollection, what: Selection) !?State.MaybeItem {
    var maybe = try findImpl(state, where, what) orelse return null;
    if (maybe.day == null and maybe.note == null and maybe.task == null) return null;
    return maybe;
}

fn findImpl(state: *State, where: ?SelectedCollection, what: Selection) !?State.MaybeItem {
    if (where) |w| switch (w.container) {
        .Journal => {
            var journal = state.getJournal(w.name) orelse
                return null;
            switch (what) {
                .ByName => |name| return .{ .day = journal.get(name) },
                .ByIndex => |index| return .{ .day = journal.Journal.getIndex(index) },
                .ByDate => |date| {
                    const name = utils.formatDateBuf(date) catch return null;
                    return .{ .day = journal.get(&name) };
                },
            }
        },
        .Directory => {
            var dir = state.getDirectory(w.name) orelse
                return null;
            switch (what) {
                .ByName => |name| return .{ .note = dir.get(name) },
                .ByIndex => unreachable,
                .ByDate => unreachable,
            }
        },
        .Tasklist => {
            var tasklist = state.getTasklist(w.name) orelse
                return null;
            try tasklist.readAll();
            switch (what) {
                .ByName => |name| return .{ .task = tasklist.get(name) },
                .ByIndex => unreachable,
                .ByDate => unreachable,
            }
        },
    };

    // don't know if journal or entry, so we try both
    switch (what) {
        .ByName => |name| return itemFromName(state, name),
        // for index, we only look at journals, but use the name to do a dir lookup
        // with the condition that the directory must have the same name as the journal
        .ByIndex => |index| {
            const maybe_day = findIndexPreferredJournal(state, index);
            if (maybe_day) |day| {
                return withMatchingNote(state, day);
            } else return null;
        },
        .ByDate => |date| {
            const name = utils.formatDateBuf(date) catch return null;
            return itemFromName(state, &name);
        },
    }
    return null;
}

fn withMatchingNote(state: *State, day: Item) ?State.MaybeItem {
    var maybe_item: State.MaybeItem = .{ .day = day };

    const jname = day.Day.journal.description.name;
    const dir = state.getDirectory(jname) orelse
        return maybe_item;

    if (dir.get(day.getName())) |note| {
        maybe_item.note = note;
    }
    return maybe_item;
}

fn itemFromName(state: *State, name: []const u8) ?State.MaybeItem {
    const maybe_note: ?Item = for (state.directories) |*c| {
        if (c.get(name)) |item| {
            break item;
        }
    } else null;
    const maybe_day: ?Item = for (state.journals) |*c| {
        if (c.get(name)) |item| {
            break item;
        }
    } else null;
    return .{ .day = maybe_day, .note = maybe_note };
}

///
pub fn parseJournalDirectoryItemlistFlag(
    arg: cli.Arg,
    itt: *cli.ArgIterator,
    allow_short: bool,
) !?SelectedCollection {
    const j: ?u8 = if (allow_short) 'j' else null;
    const d: ?u8 = if (allow_short) 'd' else null;
    const t: ?u8 = if (allow_short) 't' else null;

    if (arg.is(j, "journal")) {
        const value = try itt.getValue();
        return cli.SelectedCollection.from(
            .Journal,
            value.string,
        );
    } else if (arg.is(d, "dir") or arg.is(null, "directory")) {
        const value = try itt.getValue();
        return cli.SelectedCollection.from(
            .Directory,
            value.string,
        );
    } else if (arg.is(t, "tasklist")) {
        const value = try itt.getValue();
        return cli.SelectedCollection.from(
            .Tasklist,
            value.string,
        );
    }
    return null;
}

pub fn getSelectedCollectionPositional(itt: *cli.ArgIterator) !SelectedCollection {
    var p1 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;
    var p2 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;

    var collection_type: State.CollectionType = if (std.mem.eql(u8, "journal", p1.string))
        .Journal
    else if (std.mem.eql(u8, "directory", p1.string))
        .Directory
    else if (std.mem.eql(u8, "tasklist", p1.string))
        .Tasklist
    else
        return cli.CLIErrors.BadArgument;
    var name = p2.string;

    return SelectedCollection.from(collection_type, name);
}
