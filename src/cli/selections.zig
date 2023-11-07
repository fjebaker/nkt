const std = @import("std");

const utils = @import("../utils.zig");
const cli = @import("../cli.zig");

const State = @import("../State.zig");
const Item = State.Item;

const CollectionType = State.CollectionType;
const Date = utils.Date;

pub const SelectionError = error{
    AmbiguousSelection,
    ChildAlreadyExists,
    DuplicateSelection,
    IncompatibleSelection,
    InvalidSelection,
    NoSuchCollection,
    NoSuchItem,
    UnknownCollection,
};

pub const SelectionSet = enum {
    ByIndex,
    ByDate,
    ByName,
};

pub const ItemSelection = union(enum) {
    ByIndex: usize,
    ByDate: Date,
    ByName: []const u8,

    pub fn today() ItemSelection {
        const date = Date.now();
        return .{ .ByDate = date };
    }
};

pub const CollectionSelection = struct {
    container: CollectionType,
    name: []const u8,
};

pub const Selection = struct {
    item: ?ItemSelection = null,
    collection: ?CollectionSelection = null,
    tag: ?[]const u8 = null,

    pub fn positionalNamedCollection(itt: *cli.ArgIterator) !Selection {
        var p1 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;
        var p2 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;

        var collection_type: ?State.CollectionType = if (std.mem.eql(u8, "journal", p1.string))
            .Journal
        else if (std.mem.eql(u8, "directory", p1.string))
            .Directory
        else if (std.mem.eql(u8, "tasklist", p1.string))
            .Tasklist
        else
            null;

        var name = p2.string;

        if (collection_type) |t| {
            return .{
                .collection = .{ .container = t, .name = name },
            };
        } else if (std.mem.eql(u8, "tag", p1.string)) {
            return .{ .tag = p2.string };
        }

        return cli.CLIErrors.BadArgument;
    }

    pub fn validate(s: *Selection, what: enum { Item, Collection, Both }) bool {
        const bad = switch (what) {
            .Item => (s.item == null),
            .Collection => (s.collection == null),
            .Both => (s.item == null or s.collection == null),
        };
        return !bad;
    }

    /// Use selection to attempt to resolve an item in the state. Returns null
    /// if no item found.
    pub fn find(s: *Selection, state: *State) !?State.MaybeItem {
        if (s.item == null) return null;

        const maybe = try findImpl(state, s.collection, s.item.?) orelse
            return null;

        if (maybe.day == null and maybe.note == null and maybe.task == null)
            return null;

        return maybe;
    }

    /// Get today as an item selector. Does not set a collection.
    pub fn today() Selection {
        return .{ .item = ItemSelection.today() };
    }

    fn qualifiedIndex(s: *Selection, string: []const u8) !?usize {
        if (string.len > 1) {
            const slice = string[1..];
            const collection: CollectionSelection = switch (string[0]) {
                // return defaults for each
                't' => .{ .container = .Tasklist, .name = "todo" },
                'j' => .{ .container = .Journal, .name = "diary" },
                // cannot select note by index
                else => return null,
            };
            if (allNumeric(slice)) {
                const index = try std.fmt.parseInt(usize, slice, 10);
                if (s.collection != null) {
                    if (s.collection.?.container != collection.container) {
                        return SelectionError.AmbiguousSelection;
                    }
                }
                s.collection = collection;
                return index;
            }
        }
        return null;
    }

    /// Parse input string into a Selection. Does not validate that the
    /// selection exists. Will raise an error if cannot parse positional.
    pub fn parse(s: *Selection, arg: cli.Arg, itt: *cli.ArgIterator) !bool {
        if (arg.flag) {
            return try s.parseCollection(arg, itt);
        } else {
            try s.parseItem(arg);
            return true;
        }
    }

    pub fn parseCollection(s: *Selection, arg: cli.Arg, itt: *cli.ArgIterator) !bool {
        if (try parseCollectionFlags(arg, itt, false)) |collection| {
            if (s.collection != null) {
                if (s.collection.?.container != collection.container) {
                    return SelectionError.AmbiguousSelection;
                }
            }
            s.collection = collection;
            return true;
        }
        return false;
    }

    pub fn parseCollectionPrefixed(
        s: *Selection,
        comptime prefix: []const u8,
        arg: cli.Arg,
        itt: *cli.ArgIterator,
    ) !bool {
        if (try parseCollectionCustom(prefix, arg, itt, false)) |collection| {
            if (s.collection != null) {
                if (s.collection.?.container != collection.container) {
                    return SelectionError.AmbiguousSelection;
                }
            }
            s.collection = collection;
            return true;
        }
        return false;
    }

    /// Parse an item from a positional argument. Raises error if cannot parse.
    pub fn parseItem(s: *Selection, arg: cli.Arg) !void {
        const item = try s.parseItemImpl(arg.string);
        if (s.item != null) return cli.CLIErrors.TooManyArguments;
        s.item = item;
    }

    fn parseItemImpl(s: *Selection, input: []const u8) !ItemSelection {
        if (std.mem.eql(u8, input, "today") or std.mem.eql(u8, input, "t")) {
            return ItemSelection.today();
        } else if (try s.qualifiedIndex(input)) |index| {
            return .{ .ByIndex = index };
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

    pub const COLLECTION_FLAG_HELP =
        \\     --tl/--tasklist <n>   name of tasklist
        \\     --journal <n>         name of journal
        \\     --dir/--directory <n> name of directory
        \\
    ;

    fn parseCollectionFlags(
        arg: cli.Arg,
        itt: *cli.ArgIterator,
        comptime allow_short: bool,
    ) !?CollectionSelection {
        return parseCollectionCustom("", arg, itt, allow_short);
    }

    /// Parse ArgIterator into a ItemSelection. Does not validate that the
    /// selection exists. If no positional argument is available, returns null,
    /// allowing caller to set defaults.
    pub fn initOptionalItem(
        itt: *cli.ArgIterator,
    ) !?Selection {
        var s: Selection = .{};

        const arg = (try itt.next()) orelse return null;
        if (arg.flag) {
            itt.rewind();
            return null;
        }

        return try s.parseItemImpl(arg.string);
    }

    pub fn getItemName(s: *const Selection, alloc: std.mem.Allocator) ![]const u8 {
        switch (s.item.?) {
            .ByDate => |date| {
                const date_string = try utils.formatDateBuf(date);
                return try alloc.dupe(u8, &date_string);
            },
            .ByName => |name| return try alloc.dupe(u8, name),
            .ByIndex => unreachable,
        }
    }
};

fn parseCollectionCustom(
    comptime prefix: []const u8,
    arg: cli.Arg,
    itt: *cli.ArgIterator,
    comptime allow_short: bool,
) !?CollectionSelection {
    const j: ?u8 = if (allow_short) 'j' else null;
    const d: ?u8 = if (allow_short) 'd' else null;
    const t: ?u8 = if (allow_short) 't' else null;

    if (arg.is(j, prefix ++ "journal")) {
        const value = try itt.getValue();
        return .{
            .container = .Journal,
            .name = value.string,
        };
    } else if (stringIn(
        arg.string,
        &.{ prefix ++ "dir", prefix ++ "directory" },
    ) or arg.is(d, null)) {
        const value = try itt.getValue();
        return .{
            .container = .Directory,
            .name = value.string,
        };
    } else if (stringIn(
        arg.string,
        &.{ prefix ++ "tl", prefix ++ "tasklist" },
    ) or arg.is(t, null)) {
        const value = try itt.getValue();
        return .{
            .container = .Tasklist,
            .name = value.string,
        };
    }
    return null;
}

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

fn findImpl(state: *State, where: ?CollectionSelection, what: ItemSelection) !?State.MaybeItem {
    // if a where is given, we search there
    if (where) |w| switch (w.container) {
        .Journal => {
            var journal = state.getJournal(w.name) orelse
                return null;
            switch (what) {
                .ByName => |name| return .{ .day = journal.get(name) },
                .ByIndex => |index| return .{
                    .day = journal.Journal.getIndex(index),
                },
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
                .ByIndex => |i| return .{
                    .task = tasklist.Tasklist.getIndex(i),
                },
                .ByDate => unreachable,
            }
        },
    };

    // don't know collection type, so we try to be clever
    switch (what) {
        .ByName => |name| return try itemFromName(state, name),
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
            return try itemFromName(state, &name);
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

fn itemFromName(state: *State, name: []const u8) !?State.MaybeItem {
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
    const maybe_task: ?Item = for (state.tasklists) |*c| {
        try c.readAll();
        if (c.get(name)) |item| {
            break item;
        }
    } else null;
    return .{ .day = maybe_day, .note = maybe_note, .task = maybe_task };
}

fn stringIn(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| {
        if (std.mem.eql(u8, o, s))
            return true;
    }
    return false;
}

pub fn parseDateTimeLike(arg: cli.Arg, itt: *cli.ArgIterator, match: []const u8) !?utils.Date {
    if (arg.is(null, match)) {
        const string = (try itt.getValue()).string;
        // common substitutions
        const date = try parseDateTimeLikeImpl(
            if (std.mem.eql(u8, string, "tonight"))
                "today evening"
            else
                string,
        );
        return date;
    }
    return null;
}

fn parseDateTimeLikeImpl(string: []const u8) !utils.Date {
    var itt = std.mem.tokenize(u8, string, " ");
    const date_like = itt.next() orelse return cli.CLIErrors.BadArgument;
    const time_like = itt.next() orelse "23:59:59";
    if (itt.next()) |_| return cli.CLIErrors.TooManyArguments;

    var day = blk: {
        if (cli.selections.isDate(date_like)) {
            break :blk try utils.toDate(date_like);
        } else if (std.mem.eql(u8, date_like, "today")) {
            break :blk utils.Date.now();
        } else if (std.mem.eql(u8, date_like, "tomorrow")) {
            var today = utils.Date.now();
            break :blk today.shiftDays(1);
        } else return cli.CLIErrors.BadArgument;
    };

    const time = blk: {
        if (cli.selections.isTime(date_like)) {
            break :blk try utils.toTime(time_like);
        } else if (std.mem.eql(u8, time_like, "morning")) {
            break :blk comptime try utils.toTime("08:00:00");
        } else if (std.mem.eql(u8, time_like, "lunch")) {
            break :blk comptime try utils.toTime("13:00:00");
        } else if (std.mem.eql(u8, time_like, "end-of-day")) {
            break :blk comptime try utils.toTime("17:00:00");
        } else if (std.mem.eql(u8, time_like, "evening")) {
            break :blk comptime try utils.toTime("19:00:00");
        } else if (std.mem.eql(u8, time_like, "night")) {
            break :blk comptime try utils.toTime("23:00:00");
        } else break :blk utils.Time{ .hour = 13, .minute = 0, .second = 0 };
    };

    day.time.hour = time.hour;
    day.time.minute = time.minute;
    day.time.second = time.second;

    return day;
}

fn testTimeParsing(s: []const u8, date: utils.Date) !void {
    const eq = std.testing.expectEqual;
    const parsed = try parseDateTimeLikeImpl(s);

    try eq(parsed.date.day, date.date.day);
    try eq(parsed.time.hour, date.time.hour);
}

test "time parsing" {
    var nowish = utils.Date.now();
    nowish.time.hour = 13;
    nowish.time.minute = 0;
    nowish.time.second = 0;

    try testTimeParsing("tomorrow", nowish.shiftDays(1));
}
