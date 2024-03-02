const std = @import("std");

const cli = @import("cli.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const Journal = @import("topology/Journal.zig");
const Directory = @import("topology/Directory.zig");
const Tasklist = @import("topology/Tasklist.zig");

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

pub const Method = enum { ByIndex, ByQualifiedIndex, ByDate, ByName };

pub const Selector = union(Method) {
    ByIndex: usize,
    ByQualifiedIndex: struct {
        qualifier: u8,
        index: usize,
    },
    ByDate: time.Date,
    ByName: []const u8,

    pub fn today() Method {
        const date = time.Date.now();
        return .{ .ByDate = date };
    }
};

/// Structure representing the resolution of a `Selection`
pub const Item = union(enum) {
    Entry: struct {
        journal: Journal,
        entry: Journal.Entry,
    },
    Day: struct {
        journal: Journal,
        day: Journal.Day,
    },
    Note: struct {
        directory: Directory,
        note: Directory.Note,
    },
    Task: struct {
        tasklist: Tasklist,
        task: Tasklist.Task,
    },

    fn eql(i: Item, j: Item) bool {
        if (std.meta.activeTag(i) != std.meta.activeTag(j))
            return false;
        switch (i) {
            .Entry => |is| {
                const js = j.Entry;
                return std.mem.eql(u8, js.entry.text, is.entry.text);
            },
            .Day => |id| {
                const jd = j.Day;
                return std.mem.eql(u8, jd.day.name, id.day.name) and
                    std.mem.eql(
                    u8,
                    id.journal.descriptor.name,
                    id.journal.descriptor.name,
                );
            },
            .Note => |in| {
                const jn = j.Note;
                return std.mem.eql(u8, in.note.name, jn.note.name) and
                    std.mem.eql(
                    u8,
                    in.directory.descriptor.name,
                    jn.directory.descriptor.name,
                );
            },
            .Task => |it| {
                const jt = j.Task;
                return std.mem.eql(u8, it.task.title, jt.task.title) and
                    std.mem.eql(
                    u8,
                    it.tasklist.descriptor.name,
                    jt.tasklist.descriptor.name,
                );
            },
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
        return .{ .item = null, .err = err };
    }

    fn ok(item: Item) ResolveResult {
        return .{ .item = item, .err = null };
    }
};

fn retrieveFromJournal(s: Selector, journal: *Journal) !ResolveResult {
    const day_list = journal.info.days;
    const name: []const u8 = switch (s) {
        // TODO: translate these by days ago
        .ByIndex => |i| day_list[day_list.len - i - 1].name,
        .ByQualifiedIndex => |qi| day_list[day_list.len - qi.index - 1].name,

        .ByDate => |d| &(try time.formatDateBuf(d)),
        .ByName => |n| n,
    };
    const day = journal.getDay(name) orelse
        return ResolveResult.throw(Root.Error.NoSuchItem);
    return ResolveResult.ok(
        .{ .Day = .{ .journal = journal.*, .day = day } },
    );
}

fn retrieveFromDirectory(s: Selector, directory: *Directory) !ResolveResult {
    const name: []const u8 = switch (s) {
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

/// Struct representing the selection made
pub const Selection = struct {
    /// The type of the collection selected
    collection_type: ?Root.CollectionType = null,
    /// The name of the collection selected
    collection_name: ?[]const u8 = null,

    /// The selector used to select the item
    selector: ?Selector = null,

    fn resolve(s: Selection, root: *Root) !ResolveResult {
        const selector = s.selector orelse
            return ResolveResult.throw(Error.UnknownSelection);
        if (s.collection_type) |ct| {
            switch (ct) {
                .CollectionJournal => {
                    const name = s.collection_name orelse
                        root.info.default_journal;
                    std.log.default.debug("Looking up journal '{s}'", .{name});
                    var journal = (try root.getJournal(name)) orelse
                        return ResolveResult.throw(Error.UnknownSelection);
                    return try retrieveFromJournal(selector, &journal);
                },
                .CollectionDirectory => {
                    const name = s.collection_name orelse
                        root.info.default_directory;
                    std.log.default.debug("Looking up directory '{s}'", .{name});
                    var directory = (try root.getDirectory(name)) orelse
                        return ResolveResult.throw(Error.UnknownSelection);
                    return try retrieveFromDirectory(selector, &directory);
                },
                else => unreachable,
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
            if (r.item) |_| return r;
        }

        return ResolveResult.throw(Error.UnknownSelection);
    }

    /// Resolve the selection from the `Root`. Errors are reported back to the
    /// terminal. Returns an `Item`.
    pub fn resolveReportError(s: Selection, root: *Root) !Item {
        return (try s.resolve(root)).retrieve() catch |err| {
            return err;
        };
    }
};

fn testSelectionResolve(
    root: *Root,
    s: []const u8,
    journal: ?[]const u8,
    directory: ?[]const u8,
    tasklist: ?[]const u8,
    expected: Item,
) !void {
    var selection: Selection = .{};
    const selector = try asSelector(s);
    try addSelector(&selection, selector);

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
    var alloc = std.testing.allocator;
    var root = Root.new(alloc);
    defer root.deinit();

    try root.addInitialCollections();

    var j = (try root.getJournal(root.info.default_journal)).?;
    defer j.deinit();
    const day = try j.addNewEntryFromText("hello world", &.{});
    try testSelectionResolve(
        &root,
        "0",
        null,
        null,
        null,
        .{ .Day = .{ .day = day, .journal = j } },
    );

    var d = (try root.getDirectory(root.info.default_directory)).?;
    defer d.deinit();
    const note = try d.addNewNoteByName("stuff", .{});
    try testSelectionResolve(
        &root,
        "stuff",
        null,
        null,
        null,
        .{ .Note = .{ .note = note, .directory = d } },
    );
}

fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Counts the occurances of `spacer` in `string` and ensures all non spacer
/// characters are digits, else returns null. Returns `spacer` count.
fn formattedDigitFilter(comptime spacer: u8, string: []const u8) ?usize {
    var spacer_count: usize = 0;
    for (string) |c| {
        if (!std.ascii.isDigit(c) and c != spacer) return null;
        if (c == spacer) spacer_count += 1;
    }
    return spacer_count;
}

fn isDate(string: []const u8) bool {
    if (formattedDigitFilter('-', string)) |count| {
        if (count == 2) return true;
    }
    return false;
}

fn isTime(string: []const u8) bool {
    if (formattedDigitFilter(':', string)) |count| {
        if (count == 2) return true;
    }
    return false;
}

fn asSelector(arg: []const u8) !Selector {
    // are we an index
    if (allNumeric(arg)) {
        return .{ .ByIndex = try std.fmt.parseInt(usize, arg, 10) };
    } else if (arg.len > 1 and
        std.ascii.isAlphabetic(arg[0]) and
        allNumeric(arg[1..]))
    {
        return .{ .ByQualifiedIndex = .{
            .qualifier = arg[0],
            .index = try std.fmt.parseInt(usize, arg[1..], 10),
        } };
    } else if (isDate(arg)) {
        return .{ .ByDate = try time.toDate(arg) };
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
                if (directory != null) return .{
                    .has = ct,
                    .was_given = .CollectionDirectory,
                };
                if (tasklist != null) return .{
                    .has = ct,
                    .was_given = .CollectionTasklist,
                };
                selection.collection_name = journal;
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
                selection.collection_name = journal;
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
                selection.collection_name = journal;
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
            selection.collection_type = .CollectionJournal;
        }
        if (directory) |txt| {
            selection.collection_name = txt;
            selection.collection_type = .CollectionDirectory;
        }
        if (tasklist) |txt| {
            selection.collection_name = txt;
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
    });
    try testSelectionParsing("t0", null, null, null, .{
        .selector = .{
            .ByQualifiedIndex = .{ .index = 0, .qualifier = 't' },
        },
        .collection_type = .CollectionTasklist,
    });
    try testSelectionParsing("hello", null, "place", null, .{
        .selector = .{
            .ByName = "hello",
        },
        .collection_type = .CollectionDirectory,
        .collection_name = "place",
    });
    try std.testing.expectError(
        Error.IncompatibleSelection,
        testSelectionParsing("0", null, "place", null, .{}),
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

/// Parse the selection from a `cli.ParsedArguments` structure that has been
/// augmented with `selectHelp`. Will report errors to stderr.
pub fn fromArgs(
    comptime T: type,
    selector_string: []const u8,
    args: T,
) !Selection {
    var selection: Selection = .{};
    const selector = try asSelector(selector_string);

    try addSelector(&selection, selector);
    try addFlagsReportError(
        &selection,
        args.journal,
        args.directory,
        args.tasklist,
    );
    return selection;
}

/// Add `cli.ArgumentDescriptor` for the selection methods. Provide the name
/// and (contextual) help for the main selection, and the various flags will be
/// automatically added. Use `fromArgs` to retrieve the selection.
pub fn selectHelp(
    comptime name: []const u8,
    comptime help: []const u8,
) []const cli.ArgumentDescriptor {
    const args: []const cli.ArgumentDescriptor = &.{
        .{
            .arg = name,
            .help = help,
            .required = true,
        },
        .{
            .arg = "--journal journal",
            .help = help,
        },
        .{
            .arg = "--directory directory",
            .help = help,
        },
        .{
            .arg = "--tasklist tasklist",
            .help = help,
        },
    };
    return args;
}
