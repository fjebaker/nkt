const std = @import("std");

const utils = @import("utils.zig");
const cli = @import("cli.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const Journal = @import("topology/Journal.zig");
const Directory = @import("topology/Directory.zig");
const Tasklist = @import("topology/Tasklist.zig");

const Item = @import("abstractions.zig").Item;

const logger = std.log.scoped(.selection);

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

/// The different methods that can be used to select items in the topology
pub const Method = enum {
    /// An index is a single number, like `1`, `21`
    ByIndex,

    /// A qualified index is a number with some single character in front of
    /// it, like `t3`, or `k8`
    ByQualifiedIndex,

    /// Date is a parsed (semantic) time-like
    ByDate,

    /// Name is the name of an entry or item
    ByName,

    /// Select by a hash `/ab24f`
    ByHash,
};

/// An implementation of the different `Method` of selection. Used to return
/// what a user has selected and through which method their selection will be
/// resolved.
pub const Selector = union(Method) {
    ByIndex: usize,
    ByQualifiedIndex: struct {
        qualifier: u8,
        index: usize,
    },
    ByDate: time.Date,
    ByName: []const u8,
    ByHash: u64,

    /// Get a selector that represent the date today
    pub fn today() Method {
        const date = time.Date.now();
        return .{ .ByDate = date };
    }

    /// Get the index of a `ByIndex` or `ByQualifiedIndex` selector. Will hit
    /// an unreachable if the selector is of the wrong type.
    pub fn getIndex(self: *const Selector) usize {
        return switch (self.*) {
            .ByIndex => |i| i,
            .ByQualifiedIndex => |i| i.index,
            else => unreachable,
        };
    }

    /// Turn an argument string into a `Selector`
    pub fn initFromString(arg: []const u8) !Selector {
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
};

fn testAsSelector(arg: []const u8, comptime expected: Selector) !void {
    const s = try Selector.initFromString(arg);
    try std.testing.expectEqualDeep(expected, s);
}

test "Selector.initFromString" {
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

/// Modifers for the selction that can impact how specifics of a selection are
/// resolved
pub const Modifiers = struct {
    time: ?[]const u8 = null,
    last: bool = false,
};

/// Configuration given to the collections to help resolve a `select`
pub const SelectionConfig = struct {
    now: time.Time,
    mod: Modifiers,

    /// Used to assert no modifiers have been set
    pub fn noModifiers(s: SelectionConfig) !void {
        const cond =
            s.mod.last == false and
            s.mod.time == null;

        if (!cond) {
            return error.InvalidSelection;
        }
    }

    /// Used to assert only one modifier is set
    pub fn zeroOrOne(s: SelectionConfig) !void {
        var count: usize = 0;
        if (s.mod.last == true) count += 1;
        if (s.mod.time != null) count += 1;
        if (count > 1) {
            return error.InvalidSelection;
        }
    }
};

const ResolveResult = struct {
    item: ?Item,
    err: ?anyerror,

    fn retrieve(r: ResolveResult) !Item {
        return r.item orelse return r.err.?;
    }

    fn throw(err: anyerror) ResolveResult {
        logger.debug("ResolveResult error: {!}", .{err});
        return .{ .item = null, .err = err };
    }

    fn ok(item: Item) ResolveResult {
        return .{ .item = item, .err = null };
    }
};

fn retrieveFromCollection(
    selector: Selector,
    root: *Root,
    comptime ct: Root.CollectionType,
    name: []const u8,
    config: SelectionConfig,
) !ResolveResult {
    logger.debug(
        "Looking up collection {s}->'{s}'",
        .{ @tagName(ct), name },
    );
    var col = (try root.getCollection(name, ct)) orelse
        return ResolveResult.throw(Error.UnknownSelection);
    const item = col.select(selector, config) catch |err| {
        switch (err) {
            error.NoSuchItem, error.InvalidSelection => return ResolveResult.throw(err),
            else => return err,
        }
    };
    const it: Item = switch (ct) {
        .CollectionJournal => if (item.entry) |entry|
            .{ .Entry = .{
                .journal = col,
                .day = item.day,
                .entry = entry,
            } }
        else
            .{ .Day = .{
                .journal = col,
                .day = item.day,
            } },
        .CollectionDirectory => .{
            .Note = .{ .directory = col, .note = item },
        },
        .CollectionTasklist => .{
            .Task = .{ .tasklist = col, .task = item },
        },
    };
    return ResolveResult.ok(it);
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
                logger.debug("Resolve returned {!}", .{err});
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

    /// Configuration for the selection query
    modifiers: Modifiers = .{},

    /// True if the collection was specified on the command line
    collection_provided: bool = false,

    /// Initialize a selection query
    pub fn init() Selection {
        return .{};
    }

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

    fn implResolve(s: Selection, root: *Root, config: SelectionConfig) !ResolveResult {
        // if no item selection is given, we resolve a whole collection instead
        const selector = s.selector orelse
            return try s.resolveCollection(root);

        switch (selector) {
            .ByName => |name| {
                logger.debug("Selector name: {s}", .{name});
            },
            else => {
                logger.debug("Selector: {any}", .{selector});
            },
        }

        const ct = s.collection_type orelse {
            return ResolveResult.throw(Error.UnknownSelection);
        };

        switch (ct) {
            inline else => |t| {
                if (s.collection_name) |name| {
                    return try retrieveFromCollection(
                        s.selector.?,
                        root,
                        t,
                        name,
                        config,
                    );
                } else {
                    logger.debug(
                        "No collection name given, using default search order",
                        .{},
                    );

                    // first look in the default, then look in all the rest
                    const default_name = root.defaultCollectionName(t);
                    const default_r = try retrieveFromCollection(
                        s.selector.?,
                        root,
                        t,
                        default_name,
                        config,
                    );

                    if (unwrapCanary(default_r)) |rr| {
                        return rr;
                    }

                    // now try all the others of the same collection type
                    for (root.getAllDescriptor(t)) |d| {
                        // skip the one we've already done
                        if (std.mem.eql(u8, default_name, d.name)) continue;
                        const r = try retrieveFromCollection(
                            s.selector.?,
                            root,
                            t,
                            d.name,
                            config,
                        );
                        if (unwrapCanary(r)) |rr| {
                            return rr;
                        }
                    }
                }
            },
        }
        return ResolveResult.throw(Error.UnknownSelection);
    }

    fn resolve(s: Selection, root: *Root) !ResolveResult {
        const config: SelectionConfig = .{
            .now = time.Time.now(),
            .mod = s.modifiers,
        };

        if (s.collection_type != null) {
            if (unwrapCanary(try s.implResolve(root, config))) |rr| {
                logger.debug("Item resolved: {s}", .{rr.item.?.getPath()});
                return rr;
            }
        } else {
            if (s.collection_name == null) {
                // try different collections and see if one resolves
                for (&[_]Root.CollectionType{
                    .CollectionDirectory,
                    .CollectionJournal,
                    .CollectionTasklist,
                }) |ct| {
                    var canary = s;
                    canary.collection_type = ct;
                    const r = try canary.implResolve(root, config);
                    if (unwrapCanary(r)) |rr| {
                        logger.debug("Item resolved: {s}", .{rr.item.?.getPath()});
                        return rr;
                    }
                }
            }
        }

        logger.debug("Item could not be resolved", .{});
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
            return cli.throwError(
                err,
                "Selection is not concrete enough to resolve to an item",
                .{},
            );
        },
        Error.UnknownSelection => {
            return cli.throwError(
                err,
                "Selection is unknown.",
                .{},
            );
        },
        Root.Error.NoSuchItem => {
            return cli.throwError(
                err,
                "Cannot find item.",
                .{},
            );
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
    var selection = Selection.init();
    if (s) |str| {
        const selector = try Selector.initFromString(str);
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
                            selection.selector = .{
                                .ByDate = time.shiftBack(time.Time.now(), i),
                            };
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
    const selector = try Selector.initFromString(string);
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
    const selector = try Selector.initFromString(item);

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

/// Parse the selection from a `cli.Parsed` structure that has been
/// augmented with `selectHelp`. Will report errors to stderr.
pub fn fromArgs(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
) !Selection {
    return implArgsPrefixed("", T, selector_string, args, false);
}

/// Just like `fromArgs` but will not throw any errors from validation.
pub fn fromArgsForgiving(
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
) !Selection {
    return implArgsPrefixed("", T, selector_string, args, true);
}

/// Like `fromArgs` but with the flags prefixed with a given string.
/// Like `fromArgs` but with the flags prefixed with a given string.
pub fn fromArgsPrefixed(
    comptime prefix: []const u8,
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
) !Selection {
    return implArgsPrefixed(prefix, T, selector_string, args, false);
}

fn implArgsPrefixed(
    comptime prefix: []const u8,
    comptime T: type,
    selector_string: ?[]const u8,
    args: T,
    forgiving: bool,
) !Selection {
    var selection = Selection.init();

    if (selector_string) |ss| {
        const selector = try Selector.initFromString(ss);
        try addSelector(&selection, selector);
    }

    if (try addFlags(
        &selection,
        @field(args, prefix ++ "journal"),
        @field(args, prefix ++ "directory"),
        @field(args, prefix ++ "tasklist"),
    )) |info| {
        if (!forgiving) {
            return cli.throwError(
                Error.IncompatibleSelection,
                "Item selected '{s}' but flag is for '{s}'.",
                .{ @tagName(info.has), @tagName(info.was_given) },
            );
        }
    }

    const entry_time = @field(args, prefix ++ "time");
    // add the various modifiers to the selection
    if (entry_time) |t| {
        if (!forgiving) {
            // assert we are selecting a journal or null
            if (selection.collection_type) |ct| {
                if (ct != .CollectionJournal) {
                    return cli.throwError(
                        Error.IncompatibleSelection,
                        "Cannot select a time for collection type '{s}'",
                        .{@tagName(ct)},
                    );
                }
            }

            // assert the format of the time is okay
            if (!time.isTime(t)) {
                return cli.throwError(
                    cli.CLIErrors.BadArgument,
                    "Time is invalid format: '{s}' (needs to be 'HH:MM:SS')",
                    .{t},
                );
            }
        }
        selection.modifiers.time = t;
    }

    const last = @field(args, prefix ++ "last");
    if (last) {
        selection.modifiers.last = last;
    }

    return selection;
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
            .arg = "--" ++ opts.flag_prefix ++ "last",
            .help = "Used to select the last modified item in a collection or day.",
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
