const std = @import("std");

const cli = @import("cli.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");

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

/// Struct representing the selection made
pub const Selection = struct {
    /// The type of the collection selected
    collection_type: ?Root.CollectionType = null,
    /// The name of the collection selected
    collection_name: ?[]const u8 = null,

    /// The selector used to select the item
    selector: ?Selector = null,
};

fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isDate(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isDigit(c) and c != '-') return false;
    }
    return true;
}

fn isTime(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isDigit(c) and c != ':') return false;
    }
    return true;
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
    }

    return Error.UnknownSelection;
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
    try testAsSelector("2023-12-31", .{
        .ByDate = try time.newDate(2023, 12, 31),
    });
}

pub const Parser = struct {
    itt: *cli.ArgIterator,
    selection: Selection = .{},

    pub fn init(itt: *cli.ArgIterator) Parser {
        return .{ .itt = itt };
    }

    fn parseAsFlag(_: *Parser, _: []const u8) !bool {
        return false;
    }

    fn parseAsPositional(_: *Parser, _: []const u8) !bool {
        return false;
    }

    /// Parse the selection from an arg iterator. Returns `true` if the
    /// selection has concretely resolved, meaning argument parsing for
    /// selections can cease.
    pub fn parseNextArg(self: *Parser, arg: cli.Arg) !bool {
        if (arg.flag) {
            return try self.parseAsFlag(arg.string);
        } else {
            return try self.parseAsPositional(arg.string);
        }
        // we are done from the previous call
        return true;
    }

    /// Get the selection in its current state from the arguments parsed
    pub fn selection(self: *const Parser) Selection {
        return self.selection;
    }
};

fn testParser(string: []const u8, comptime expected: Selection) !void {
    // put a test argument iterator together
    const split_args = try cli.splitArgs(std.testing.allocator, string);
    defer std.testing.allocator.free(split_args);
    var itt = cli.ArgIterator.init(split_args);

    var parser = Parser.init(&itt);
    while (try itt.next()) |arg| {
        _ = try parser.parseNextArg(arg);
    }

    const selection = parser.selection();
    _ = selection;
    _ = expected;
}
