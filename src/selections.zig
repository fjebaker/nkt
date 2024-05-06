const std = @import("std");

const utils = @import("utils.zig");
const cli = @import("cli.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const Journal = @import("topology/Journal.zig");
const Directory = @import("topology/Directory.zig");
const Tasklist = @import("topology/Tasklist.zig");

const Item = @import("abstractions.zig").Item;

pub const Error = error{
    /// Selection does not uniquely select an item
    AmbiguousSelection,

    /// Selection does not resolve, i.e. attempts to select a task but gives a
    /// directory to look in
    IncompatibleSelection,

    /// The prefix index qualifier does not resolve to a collection type
    IndexQualifierUnknown,

    /// Cannot make this selection
    InvalidSelection,

    /// This selection is not known
    UnknownSelection,

    /// Collection must be specified but was not
    UnspecifiedCollection,
};

pub const Method = enum {
    ByIndex,
    ByQualifiedIndex,
    ByDate,
    ByName,
    ByHash,
};

pub const Selector = union(Method) {
    ByIndex: usize,
    ByQualifiedIndex: struct {
        qualifier: u8,
        index: usize,
    },
    ByDate: time.Date,
    ByName: []const u8,
    ByHash: u64,

    pub fn today() Method {
        const date = time.Date.now();
        return .{ .ByDate = date };
    }
};

const ResolveResult = struct {
    item: ?Item,
    err: ?anyerror,

    fn retrieve(r: ResolveResult) !Item {
        return r.item orelse return r.err.?;
    }

    fn throw(err: anyerror) ResolveResult {
        std.log.default.debug("ResolveResult error: {!}", .{err});
        return .{ .item = null, .err = err };
    }

    fn ok(item: Item) ResolveResult {
        return .{ .item = item, .err = null };
    }
};

fn retrieveFromJournal(
    s: Selector,
    journal: *Journal,
    entry_time: ?[]const u8,
) !ResolveResult {
    const now = time.Time.now();
    const day = switch (s) {
        .ByQualifiedIndex, .ByIndex => b: {
            const index = if (s == .ByIndex)
                s.ByIndex
            else
                s.ByQualifiedIndex.index;
            std.log.default.debug("Looking up by index: {d}", .{index});
            break :b journal.getDayOffsetIndex(now, index) orelse
                return ResolveResult.throw(Root.Error.NoSuchItem);
        },
        .ByDate => |d| b: {
            const name = try time.formatDateBuf(d);
            break :b journal.getDay(&name) orelse
                return ResolveResult.throw(Root.Error.NoSuchItem);
        },
        .ByName => |name| journal.getDay(name) orelse
            return ResolveResult.throw(Root.Error.NoSuchItem),
        .ByHash => return ResolveResult.throw(Error.InvalidSelection),
    };

    if (entry_time) |t| {
        const entries = try journal.getEntries(day);
        for (entries) |entry| {
            const etime = try entry.created.formatTime();

            if (std.mem.eql(u8, t, &etime)) {
                return ResolveResult.ok(.{ .Entry = .{
                    .journal = journal.*,
                    .day = day,
                    .entry = entry,
                } });
            }
        }
        return ResolveResult.throw(Root.Error.NoSuchItem);
    }

    return ResolveResult.ok(
        .{ .Day = .{ .journal = journal.*, .day = day } },
    );
}

fn retrieveFromDirectory(s: Selector, directory: *Directory) !ResolveResult {
    const name: []const u8 = switch (s) {
        .ByHash => return ResolveResult.throw(Error.InvalidSelection),
        .ByName => |n| n,
        .ByDate => |d| &(try time.formatDateBuf(d)),
        else => return Error.InvalidSelection,
    };
    const note = directory.getNote(name) orelse
        return ResolveResult.throw(Root.Error.NoSuchItem);
    return ResolveResult.ok(
        .{ .Note = .{ .directory = directory.*, .note = note } },
    );
}

fn retrieveFromTasklist(s: Selector, tasklist: *Tasklist) !ResolveResult {
    const task: ?Tasklist.Task = switch (s) {
        .ByName => |n| try tasklist.getTask(n),
        .ByIndex, .ByQualifiedIndex => b: {
            const index = if (s == .ByIndex)
                s.ByIndex
            else
                s.ByQualifiedIndex.index;

            break :b try tasklist.getTaskByIndex(index);
        },
        .ByDate => return ResolveResult.throw(Error.InvalidSelection),
        .ByHash => |h| b: {
            if (h <= Tasklist.MINI_HASH_MAX_VALUE) {
                break :b tasklist.getTaskByMiniHash(h) catch |e|
                    return ResolveResult.throw(e);
            } else {
                break :b tasklist.getTaskByHash(h);
            }
        },
    };
    const t = task orelse
        return ResolveResult.throw(Root.Error.NoSuchItem);
    return ResolveResult.ok(
        .{ .Task = .{ .tasklist = tasklist.*, .task = t } },
    );
}

/// Internal utility method used to turn various "failed to resolve" errors
/// from canary selectors into null values to make sending the next canary less
/// verbose
fn unwrapCanary(rr: ResolveResult) ?ResolveResult {
    if (rr.err) |err| {
        switch (err) {
            Error.UnknownSelection,
            Error.InvalidSelection,
            Root.Error.NoSuchItem,
            => {
                std.log.default.debug("Resolve returned {!}", .{err});
            },
            else => {
                return ResolveResult.throw(err);
            },
        }
    }
    if (rr.item != null) return rr;
    return null;
}

/// Struct representing the selection made
pub const Selection = struct {
    /// The type of the collection selected
    collection_type: ?Root.CollectionType = null,
    /// The name of the collection selected
    collection_name: ?[]const u8 = null,

    /// The selector used to select the item
    selector: ?Selector = null,

    modifiers: struct {
        entry_time: ?[]const u8 = null,
    } = .{},

    /// True if the collection was specified on the command line
    collection_provided: bool = false,

    fn resolveCollection(s: Selection, root: *Root) !ResolveResult {
        const name = s.collection_name orelse
            return ResolveResult.throw(Error.AmbiguousSelection);
        if (s.collection_type) |ct| switch (ct) {
            .CollectionJournal => {
                const j = (try root.getJournal(name)) orelse
                    return ResolveResult.throw(Root.Error.NoSuchCollection);
                return ResolveResult.ok(
                    .{ .Collection = .{ .journal = j } },
                );
            },
            .CollectionDirectory => {
                const d = (try root.getDirectory(name)) orelse
                    return ResolveResult.throw(Root.Error.NoSuchCollection);
                return ResolveResult.ok(
                    .{ .Collection = .{ .directory = d } },
                );
            },
            .CollectionTasklist => {
                const t = (try root.getTasklist(name)) orelse
                    return ResolveResult.throw(Root.Error.NoSuchCollection);
                return ResolveResult.ok(
                    .{ .Collection = .{ .tasklist = t } },
                );
            },
        };
        return ResolveResult.throw(Error.UnknownSelection);
    }

    fn lookInCollection(
        s: Selection,
        root: *Root,
        comptime ct: Root.CollectionType,
        name: []const u8,
    ) !ResolveResult {
        std.log.default.debug(
            "Looking up collection {s}->'{s}'",
            .{ @tagName(ct), name },
        );

        var col = (try root.getCollection(name, ct)) orelse
            return ResolveResult.throw(Error.UnknownSelection);
        const selector = s.selector.?;

        switch (ct) {
            .CollectionJournal => {
                return try retrieveFromJournal(
                    selector,
                    &col,
                    s.modifiers.entry_time,
                );
            },
            .CollectionDirectory => {
                return try retrieveFromDirectory(selector, &col);
            },
            .CollectionTasklist => {
                return try retrieveFromTasklist(selector, &col);
            },
        }
    }

    fn resolve(s: Selection, root: *Root) !ResolveResult {
        // if no item selection is given, we resolve a whole collection instead
        const selector = s.selector orelse
            return try s.resolveCollection(root);

        std.log.default.debug("Selector: {s}", .{@tagName(selector)});

        if (s.collection_type) |ct| {
            switch (ct) {
                inline else => |t| {
                    if (s.collection_name) |name| {
                        return s.lookInCollection(root, t, name);
                    } else {
                        std.log.default.debug(
                            "No collection name given, using default search order",
                            .{},
                        );

                        // first look in the default, then look in all the rest
                        const default_name = root.defaultCollectionName(t);
                        const default_r = try s.lookInCollection(root, t, default_name);
                        if (unwrapCanary(default_r)) |rr| {
                            return rr;
                        }
                        // now try all the others
                        for (root.getAllDescriptor(t)) |d| {
                            const r = try s.lookInCollection(root, t, d.name);
                            if (unwrapCanary(r)) |rr| {
                                return rr;
                            }
                        }
                    }
                },
            }

            switch (ct) {
                .CollectionJournal => {
                    const name = s.collection_name orelse
                        root.info.default_journal;
                    std.log.default.debug("Looking up journal '{s}'", .{name});
                    var journal = (try root.getJournal(name)) orelse
                        return ResolveResult.throw(Error.UnknownSelection);
                    return try retrieveFromJournal(
                        selector,
                        &journal,
                        s.modifiers.entry_time,
                    );
                },
                .CollectionDirectory => {
                    const name = s.collection_name orelse
                        root.info.default_directory;
                    std.log.default.debug("Looking up directory '{s}'", .{name});
                    var directory = (try root.getDirectory(name)) orelse
                        return ResolveResult.throw(Error.UnknownSelection);
                    return try retrieveFromDirectory(selector, &directory);
                },
                .CollectionTasklist => {
                    const name = s.collection_name orelse
                        root.info.default_tasklist;
                    std.log.default.debug("Looking up tasklist '{s}'", .{name});

                    var tasklist = (try root.getTasklist(name)) orelse
                        return ResolveResult.throw(Error.UnknownSelection);
                    return try retrieveFromTasklist(selector, &tasklist);
                },
            }
        }

        // try different collections and see if one resolves
        for (&[_]Root.CollectionType{
            .CollectionDirectory,
            .CollectionJournal,
            .CollectionTasklist,
        }) |ct| {
            var canary = s;
            canary.collection_type = ct;
            const r = try canary.resolve(root);
            if (unwrapCanary(r)) |rr| {
                return rr;
            }
        }

        return ResolveResult.throw(Error.UnknownSelection);
    }

    /// Resolve the selection from the `Root`. If `NoSuchItem`, returns `null`
    /// instead of raising error. All other errors are reported back as in
    /// `resolveReportError`.
    pub fn resolveOrNull(s: Selection, root: *Root) !?Item {
        const rr = try s.resolve(root);
        return rr.retrieve() catch |err| {
            switch (err) {
                Root.Error.NoSuchItem,
                Error.UnknownSelection,
                => return null,
                else => {},
            }
            try reportResolveError(err);
            return err;
        };
    }

    /// Resolve the selection from the `Root`. Errors are reported back to the
    /// terminal. Returns an `Item`.
    pub fn resolveReportError(s: Selection, root: *Root) !Item {
        const rr = try s.resolve(root);
        return rr.retrieve() catch |err| {
            try reportResolveError(err);
            return err;
        };
    }
};

fn reportResolveError(err: anyerror) !void {
    switch (err) {
        Error.AmbiguousSelection => {
            try cli.throwError(
                err,
                "Selection is not concrete enough to resolve to an item",
                .{},
            );
            unreachable;
        },
        Error.UnknownSelection => {
            try cli.throwError(
                err,
                "Selection is unknown.",
                .{},
            );
            unreachable;
        },
        Root.Error.NoSuchItem => {
            try cli.throwError(
                err,
                "Cannot find item.",
                .{},
            );
            unreachable;
        },
        else => {},
    }
}

fn testSelectionResolve(
    root: *Root,
    s: ?[]const u8,
    journal: ?[]const u8,
    directory: ?[]const u8,
    tasklist: ?[]const u8,
    expected: Item,
) !void {
    var selection: Selection = .{};
    if (s) |str| {
        const selector = try asSelector(str);
        try addSelector(&selection, selector);
    }

    if (try addFlags(
        &selection,
        journal,
        directory,
        tasklist,
    )) |_| return Error.IncompatibleSelection;

    const rr = try selection.resolve(root);
    const item = try rr.retrieve();
    try std.testing.expect(item.eql(expected));
}

test "resolve selections" {
    const alloc = std.testing.allocator;
    var root = Root.new(alloc);
    defer root.deinit();

    _ = try time.initTimeZoneUTC(alloc);
    defer time.deinitTimeZone();

    try root.addInitialCollections();

    var j = (try root.getJournal(root.info.default_journal)).?;
    const day = try j.addNewEntryFromText("hello world", &.{});
    try testSelectionResolve(
        &root,
        "0",
        null,
        null,
        null,
        .{ .Day = .{ .day = day, .journal = j } },
    );
    try testSelectionResolve(
        &root,
        null,
        root.info.default_journal,
        null,
        null,
        .{ .Collection = .{ .journal = j } },
    );
    try std.testing.expectError(
        Error.IncompatibleSelection,
        testSelectionResolve(
            &root,
            "0",
            null,
            null,
            root.info.default_directory,
            .{ .Collection = .{ .journal = j } },
        ),
    );

    var d = (try root.getDirectory(root.info.default_directory)).?;
    const note = try d.addNewNoteByName("stuff", .{});
    try testSelectionResolve(
        &root,
        "stuff",
        null,
        null,
        null,
        .{ .Note = .{ .note = note, .directory = d } },
    );
    try testSelectionResolve(
        &root,
        null,
        null,
        root.info.default_directory,
        null,
        .{ .Collection = .{ .directory = d } },
    );
}

fn asSelector(arg: []const u8) !Selector {
    // are we an index
    if (utils.allNumeric(arg)) {
        return .{ .ByIndex = try std.fmt.parseInt(usize, arg, 10) };
    } else if (arg.len > 1 and
        arg[0] == '/' and
        utils.allAlphanumeric(arg[1..]))
    {
        return .{
            .ByHash = try std.fmt.parseInt(u64, arg[1..], 16),
        };
    } else if (arg.len > 1 and
        std.ascii.isAlphabetic(arg[0]) and
        utils.allNumeric(arg[1..]))
    {
        return .{ .ByQualifiedIndex = .{
            .qualifier = arg[0],
            .index = try std.fmt.parseInt(usize, arg[1..], 10),
        } };
    } else if (time.isDate(arg)) {
        return .{ .ByDate = try time.stringToDate(arg) };
    } else {
        return .{ .ByName = arg };
    }
}

fn testAsSelector(arg: []const u8, comptime expected: Selector) !void {
    const s = try asSelector(arg);
    try std.testing.expectEqualDeep(expected, s);
}

test "asSelector" {
    try testAsSelector("123", .{ .ByIndex = 123 });
    try testAsSelector("k123", .{ .ByQualifiedIndex = .{
        .qualifier = 'k',
        .index = 123,
    } });
    try testAsSelector(
        "h123.",
        .{ .ByName = "h123." },
    );
    try testAsSelector("2023-12-31", .{
        .ByDate = try time.newDate(2023, 12, 31),
    });
    try testAsSelector(
        "202312-31",
        .{ .ByName = "202312-31" },
    );
    try testAsSelector(
        "hello",
        .{ .ByName = "hello" },
    );
    try testAsSelector(
        "/123ab",
        .{ .ByHash = 0x123ab },
    );
}

/// Translate the qualifier character to a `Root.CollectionType` For example
/// `t` becomes `.CollectionTasklist`
fn qualifierToCollection(q: u8) !Root.CollectionType {
    return switch (q) {
        't' => .CollectionTasklist,
        'j' => .CollectionJournal,
        else => Error.IndexQualifierUnknown,
    };
}

fn addSelector(selection: *Selection, selector: Selector) !void {
    switch (selector) {
        .ByQualifiedIndex => |qi| {
            selection.collection_type = try qualifierToCollection(
                qi.qualifier,
            );
        },
        .ByIndex => {
            // TODO: let indexes select other collection types?
            selection.collection_type = .CollectionJournal;
        },
        else => {},
    }

    selection.selector = selector;
}

const InvalidCollectionFlag = struct {
    has: Root.CollectionType,
    was_given: Root.CollectionType,
};

/// Returns `null` if everything is good, else describes what has gone wrong with an `InvalidCollectionFlag` instance.
fn addFlags(
    selection: *Selection,
    journal: ?[]const u8,
    directory: ?[]const u8,
    tasklist: ?[]const u8,
) !?InvalidCollectionFlag {
    // do we already have a collection type
    if (selection.collection_type) |ct| {
        switch (ct) {
            .CollectionJournal => {
                if (directory != null) {
                    // TODO: this should be cleaned up
                    // want to allow `ByIndex` selections for directories
                    if (selection.selector) |s| switch (s) {
                        .ByIndex => |i| {
                            selection.selector = .{ .ByDate = time.shiftBack(time.Time.now(), i) };
                            selection.collection_name = directory;
                            selection.collection_type = .CollectionDirectory;
                            selection.collection_provided = directory != null;
                            return null;
                        },
                        else => {},
                    };
                    return .{
                        .has = ct,
                        .was_given = .CollectionDirectory,
                    };
                }
                if (tasklist != null) return .{
                    .has = ct,
                    .was_given = .CollectionTasklist,
                };
                selection.collection_name = journal;
                selection.collection_provided = journal != null;
            },
            .CollectionTasklist => {
                if (journal != null) return .{
                    .has = ct,
                    .was_given = .CollectionJournal,
                };
                if (directory != null) return .{
                    .has = ct,
                    .was_given = .CollectionDirectory,
                };
                selection.collection_name = tasklist;
                selection.collection_provided = tasklist != null;
            },
            .CollectionDirectory => {
                if (journal != null) return .{
                    .has = ct,
                    .was_given = .CollectionJournal,
                };
                if (tasklist != null) return .{
                    .has = ct,
                    .was_given = .CollectionTasklist,
                };
                selection.collection_name = directory;
                selection.collection_provided = directory != null;
            },
        }
    } else {
        // make sure no two are set
        var count: usize = 0;
        if (journal != null) count += 1;
        if (directory != null) count += 1;
        if (tasklist != null) count += 1;
        if (count > 1) return Error.AmbiguousSelection;

        // asign the one that is set
        if (journal) |txt| {
            selection.collection_name = txt;
            selection.collection_provided = true;
            selection.collection_type = .CollectionJournal;
        }
        if (directory) |txt| {
            selection.collection_name = txt;
            selection.collection_provided = true;
            selection.collection_type = .CollectionDirectory;
        }
        if (tasklist) |txt| {
            selection.collection_name = txt;
            selection.collection_provided = true;
            selection.collection_type = .CollectionTasklist;
        }
    }
    return null;
}

fn testParser(string: []const u8, comptime expected: Selection) !void {
    var selection: Selection = .{};
    const selector = try asSelector(string);
    try addSelector(&selection, selector);

    try std.testing.expectEqualDeep(expected, selection);
}

test "selection parser" {
    try testParser(
        "t4",
        .{ .selector = .{
            .ByQualifiedIndex = .{
                .qualifier = 't',
                .index = 4,
            },
        }, .collection_type = .CollectionTasklist },
    );
    try testParser(
        "hello",
        .{ .selector = .{
            .ByName = "hello",
        } },
    );
    try testParser(
        "123",
        .{ .selector = .{
            .ByIndex = 123,
        }, .collection_type = .CollectionJournal },
    );
}

fn testSelectionParsing(
    item: []const u8,
    journal: ?[]const u8,
    directory: ?[]const u8,
    tasklist: ?[]const u8,
    comptime expected: Selection,
) !void {
    var selection: Selection = .{};
    const selector = try asSelector(item);

    try addSelector(&selection, selector);
    if (try addFlags(
        &selection,
        journal,
        directory,
        tasklist,
    )) |_| return Error.IncompatibleSelection;

    try std.testing.expectEqualDeep(expected, selection);
}

test "selection parsing" {
    try testSelectionParsing("0", null, null, null, .{
        .selector = .{
            .ByIndex = 0,
        },
        .collection_type = .CollectionJournal,
        .collection_provided = false,
    });
    try testSelectionParsing("t0", null, null, null, .{
        .selector = .{
            .ByQualifiedIndex = .{ .index = 0, .qualifier = 't' },
        },
        .collection_type = .CollectionTasklist,
        .collection_provided = false,
    });
    try testSelectionParsing("hello", null, "place", null, .{
        .selector = .{
            .ByName = "hello",
        },
        .collection_type = .CollectionDirectory,
        .collection_name = "place",
        .collection_provided = true,
    });
    try std.testing.expectError(
        Error.IncompatibleSelection,
        testSelectionParsing("0", null, null, "place", .{}),
    );
    try std.testing.expectError(
        Error.AmbiguousSelection,
        testSelectionParsing("hello", null, "place", "other", .{}),
    );
}

fn addFlagsReportError(
    selection: *Selection,
    journal: ?[]const u8,
    directory: ?[]const u8,
    tasklist: ?[]const u8,
) !void {
    if (try addFlags(
        selection,
        journal,
        directory,
        tasklist,
    )) |info| {
        try cli.throwError(
            Error.IncompatibleSelection,
            "Item selected '{s}' but flag is for '{s}'.",
            .{ @tagName(info.has), @tagName(info.was_given) },
        );
        unreachable;
    }
}

fn addModifiersReportError(
    selection: *Selection,
    entry_time: ?[]const u8,
) !void {
    if (entry_time) |t| {
        // assert we are selecting a journal or null
        if (selection.collection_type) |ct| {
            if (ct != .CollectionJournal) {
                try cli.throwError(
                    Error.IncompatibleSelection,
                    "Cannot select a time for collection type '{s}'",
                    .{@tagName(ct)},
                );
                unreachable;
            }
        }

        // assert the format of the time is okay
        if (!time.isTime(t)) {
            try cli.throwError(
                cli.CLIErrors.BadArgument,
                "Time is invalid format: '{s}' (needs to be 'HH:MM:SS')",
                .{t},
            );
            unreachable;
        }
        selection.modifiers.entry_time = t;
    }
}

fn fromArgsFields(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
    comptime journal_field: []const u8,
    comptime directory_field: []const u8,
    comptime tasklist_field: []const u8,
    comptime time_field: []const u8,
) !Selection {
    var selection: Selection = .{};

    if (selector_string) |ss| {
        const selector = try asSelector(ss);
        try addSelector(&selection, selector);
    }

    try addFlagsReportError(
        &selection,
        @field(args, journal_field),
        @field(args, directory_field),
        @field(args, tasklist_field),
    );

    try addModifiersReportError(
        &selection,
        @field(args, time_field),
    );
    return selection;
}

/// Parse the selection from a `cli.Parsed` structure that has been
/// augmented with `selectHelp`. Will report errors to stderr.
pub fn fromArgs(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
) !Selection {
    return fromArgsFields(
        T,
        selector_string,
        args,
        "journal",
        "directory",
        "tasklist",
        "time",
    );
}

/// Just like `fromArgs` but will not throw any errors from validation.
pub fn fromArgsForgiving(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
) !Selection {
    var selection: Selection = .{};
    if (selector_string) |ss| {
        const selector = try asSelector(ss);
        try addSelector(&selection, selector);
    }

    if (try addFlags(
        &selection,
        args.journal,
        args.directory,
        args.tasklist,
    )) |_| {}

    if (args.time) |t| {
        selection.modifiers.entry_time = t;
    }

    return selection;
}

/// Like `fromArgs` but with the flags prefixed with a given string.
pub fn fromArgsPrefixed(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
    comptime prefix: []const u8,
) !Selection {
    return fromArgsFields(
        T,
        selector_string,
        args,
        prefix ++ "journal",
        prefix ++ "directory",
        prefix ++ "tasklist",
        prefix ++ "time",
    );
}

pub const SelectHelpOptions = struct {
    required: bool = true,
    flag_prefix: []const u8 = "",
};

/// Add `cli.ArgumentDescriptor` for the selection methods. Provide the name
/// and (contextual) help for the main selection, and the various flags will be
/// automatically added. Use `fromArgs` to retrieve the selection.
pub fn selectHelp(
    comptime name: []const u8,
    comptime help: []const u8,
    comptime opts: SelectHelpOptions,
) []const cli.ArgumentDescriptor {
    const args: []const cli.ArgumentDescriptor = &.{
        .{
            .arg = name,
            .help = help,
            .required = opts.required,
            .completion = "{compadd $(nkt completion item $words)}",
        },
        .{
            .arg = "--" ++ opts.flag_prefix ++ "journal journal",
            .help = "The name of a journal to select the day or entry from. If unassigned uses default journal.",
            .completion = "{compadd $(nkt completion list --collection journal)}",
        },
        .{
            .arg = "--" ++ opts.flag_prefix ++ "time HH:MM:SS",
            .help = "Augments a given selection with a given time, used for selecting e.g. individual entries.",
            .completion = "{compadd $(nkt completion item $words)}",
        },
        .{
            .arg = "--" ++ opts.flag_prefix ++ "directory directory",
            .help = "The name of the directory to select a note from. If unassigned uses default directory.",
            .completion = "{compadd $(nkt completion list --collection directory)}",
        },
        .{
            .arg = "--" ++ opts.flag_prefix ++ "tasklist tasklist",
            .help = "The name of the tasklist to select a task from. If unassigned uses default tasklist.",
            .completion = "{compadd $(nkt completion list --collection tasklist)}",
        },
    };
    return args;
}
