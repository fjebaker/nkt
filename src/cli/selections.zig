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
    chain: ?[]const u8 = null,

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
        } else if (std.mem.eql(u8, "chain", p1.string)) {
            return .{ .chain = p2.string };
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
    var col = Colloquial{ .tkn = itt, .now = utils.dateFromMs(utils.now()) };

    const date = try col.parse();
    if (col.nextOrNull()) |_|
        return cli.CLIErrors.TooManyArguments;
    return date;
}

pub const DATE_TIME_SELECTOR_HELP =
    \\Date time selection format:
    \\
    \\  'tuesday evening'
    \\  'tomorrow'
    \\  '2023-11-29 14:00:00'
    \\  'next week'           # picks the next monday
    \\  'soon'                # random time between 2 and 5 days
    \\  'end of week'         # friday end of day
    \\  'thursday'
    \\  'next thursday'       # same as above
    \\  '2 weeks'
    \\  '30 days'
    \\
    \\Weekdays specified are always in advance (specifying monday on a monday will mean
    \\next monday).
    \\
;

const Colloquial = struct {
    const Tokenizer = std.mem.TokenIterator(u8, .any);
    const DefaultTime = utils.toTime("13:00:00") catch
        @compileError("Could not default parse date");

    tkn: Tokenizer,
    now: utils.Date,

    fn _eq(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    fn setTime(_: *const Colloquial, date: utils.Date, time: utils.Time) utils.Date {
        var day = date;
        day.time.hour = time.hour;
        day.time.minute = time.minute;
        day.time.second = time.second;
        return day;
    }

    fn nextOrNull(c: *Colloquial) ?[]const u8 {
        return c.tkn.next();
    }

    fn next(c: *Colloquial) ![]const u8 {
        return c.tkn.next() orelse
            cli.CLIErrors.BadArgument;
    }

    fn optionalTime(c: *Colloquial) !utils.Time {
        const time_like = c.nextOrNull() orelse
            return DefaultTime;
        return try timeOfDay(time_like);
    }

    pub fn parse(c: *Colloquial) !utils.Date {
        var arg = try c.next();

        if (_eq(arg, "soon")) {
            var prng = std.rand.DefaultPrng.init(utils.now());
            const days_different = prng.random().intRangeAtMost(
                i32,
                3,
                5,
            );
            return c.setTime(
                c.now.shiftDays(days_different),
                DefaultTime,
            );
        } else if (_eq(arg, "next")) {
            // only those that semantically follow 'next'
            arg = try c.next();
            if (_eq(arg, "week")) {
                const monday = c.parseWeekday("monday").?;
                return c.setTime(
                    monday,
                    try c.optionalTime(),
                );
            }
        } else {
            // predicated
            if (_eq(arg, "today")) {
                return c.setTime(c.now, try c.optionalTime());
            } else if (_eq(arg, "tomorrow")) {
                return c.setTime(
                    c.now.shiftDays(1),
                    try c.optionalTime(),
                );
            } else if (cli.selections.isDate(arg)) {
                const date = try utils.toDate(arg);
                return c.setTime(date, try c.optionalTime());
            }
        }

        // mutual
        if (c.parseWeekday(arg)) |date| {
            return c.setTime(date, try c.optionalTime());
        }

        return cli.CLIErrors.BadArgument;
    }

    fn parseNextTime(c: *Colloquial) !utils.Date {
        if (c.parseWeekday(try c.next())) |date| {
            _ = date;
        }
    }

    fn parseDate(c: *Colloquial) !utils.Date {
        const arg = c.next();
        if (cli.selections.isDate(arg)) {
            return try utils.toDate(arg);
        } else if (std.mem.eql(u8, arg, "today")) {
            return utils.Date.now();
        } else if (std.mem.eql(u8, arg, "tomorrow")) {
            return c.now().shiftDays(1);
        } else return cli.CLIErrors.BadArgument;
    }

    const Weekday = utils.time.datetime.Weekday;

    fn asWeekday(arg: []const u8) ?Weekday {
        inline for (1..8) |i| {
            const weekday: Weekday = @enumFromInt(i);
            var name = @tagName(weekday);
            if (_eq(name[1..], arg[1..])) {
                if (name[0] == std.ascii.toUpper(arg[0])) {
                    return weekday;
                }
            }
        }
        return null;
    }

    fn parseWeekday(c: *const Colloquial, arg: []const u8) ?utils.Date {
        const today = c.now.date.dayOfWeek();
        const shift = daysDifferent(today, arg) orelse return null;
        return c.now.shiftDays(shift);
    }

    fn daysDifferent(today_wd: Weekday, arg: []const u8) ?i32 {
        const choice = asWeekday(arg) orelse return null;
        const today: i32 = @intCast(@intFromEnum(today_wd));
        var selected: i32 = @intCast(@intFromEnum(choice));

        if (selected <= today) {
            selected += 7;
        }
        return (selected - today);
    }

    fn _compTime(comptime s: []const u8) utils.Time {
        return utils.toTime(s) catch @compileError("Could not parse time: " ++ s);
    }

    const TIME_OF_DAY = std.ComptimeStringMap(utils.Time, .{
        .{ "morning", _compTime("08:00:00") },
        .{ "lunch", _compTime("13:00:00") },
        .{ "eod", _compTime("17:00:00") },
        .{ "end-of-day", _compTime("17:00:00") },
        .{ "evening", _compTime("19:00:00") },
        .{ "night", _compTime("23:00:00") },
    });

    fn timeOfDay(s: []const u8) !utils.Time {
        if (cli.selections.isTime(s)) {
            return try utils.toTime(s);
        }

        if (TIME_OF_DAY.get(s)) |time| return time;
        return utils.Time{ .hour = 13, .minute = 0, .second = 0 };
    }
};

fn testWeekday(now: Colloquial.Weekday, arg: []const u8, diff: i32) !void {
    const delta = Colloquial.daysDifferent(now, arg);
    try std.testing.expectEqual(delta, diff);
}

test "time selection parsing" {
    try testWeekday(.Monday, "tuesday", 1);
    try testWeekday(.Thursday, "tuesday", 5);
    try testWeekday(.Sunday, "sunday", 7);
    try testWeekday(.Wednesday, "thursday", 1);
}

fn testTimeParsing(now: utils.Date, s: []const u8, date: utils.Date) !void {
    const eq = std.testing.expectEqual;

    var itt = std.mem.tokenize(u8, s, " ");
    var col = Colloquial{ .tkn = itt, .now = now };
    const parsed = try col.parse();

    try eq(parsed.date.day, date.date.day);
    try eq(parsed.date.month, date.date.month);
    try eq(parsed.time.hour, date.time.hour);
}

test "time parsing" {
    var nowish = try utils.Date.fromDate(2023, 11, 8); // wednesday of nov
    nowish.time.hour = 13;
    nowish.time.minute = 0;
    nowish.time.second = 0;

    try testTimeParsing(nowish, "next week", nowish.shiftDays(5));
    try testTimeParsing(nowish, "tomorrow", nowish.shiftDays(1));
    try testTimeParsing(nowish, "today", nowish);
    try testTimeParsing(nowish, "thursday", nowish.shiftDays(1));
    try testTimeParsing(nowish, "tuesday", nowish.shiftDays(6));
    try testTimeParsing(
        nowish,
        "monday evening",
        nowish.shiftDays(5).shiftHours(6),
    );
    try testTimeParsing(
        nowish,
        "monday 18:00:00",
        nowish.shiftDays(5).shiftHours(5),
    );
    try testTimeParsing(
        nowish,
        "2023-11-09 15:30:00",
        nowish.shiftDays(1).shiftHours(2).shiftMinutes(30),
    );
}
