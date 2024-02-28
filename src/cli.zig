const std = @import("std");

const utils = @import("utils.zig");
const farbe = @import("farbe");
const ListIterator = utils.ListIterator;

// pub const selections = @import("cli/selections.zig");
// pub const Selection = selections.Selection;
// pub const SelectionError = selections.SelectionError;

pub const CLIErrors = error{
    BadArgument,
    CannotParseFlagAsPositional,
    InvalidFlag,
    CouldNotParse,
    DuplicateFlag,
    NoValueGiven,
    TooFewArguments,
    TooManyArguments,
    UnknownFlag,
};

fn errorString(err: CLIErrors) []const u8 {
    inline for (@typeInfo(CLIErrors).ErrorSet.?) |e| {
        const same_name = err == @field(anyerror, e.name);
        if (same_name) {
            return e.name;
        }
    }
    unreachable;
}

/// Wrapper for returning errors with helpful messages printed to `stderr`
pub fn throwError(comptime err: CLIErrors, comptime fmt: []const u8, args: anytype) !void {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = errorString(err);

    // do we use color?
    if (stderr.isTty()) {
        const f = farbe.ComptimeFarbe.init().fgRgb(255, 0, 0).bold();
        try f.write(writer, "{s}: ", .{err_string});
    } else {
        try writer.print("{s}: ", .{err_string});
    }
    try writer.print(fmt ++ "\n", args);

    // let the OS clean up
    std.process.exit(1);
}

/// Argument abstraction
pub const Arg = struct {
    string: []const u8,

    flag: bool = false,
    index: ?usize = null,

    /// Convenience method for checking if a flag argument is either a `-s`
    /// (short) or `--long`. Returns true if either is matched, else false.
    /// Returns false if the argument is positional.
    pub fn is(self: *const Arg, short: ?u8, long: ?[]const u8) bool {
        if (!self.flag) return false;
        if (short) |s| {
            if (self.string.len == 1 and s == self.string[0]) {
                return true;
            }
        }
        if (long) |l| {
            if (std.mem.eql(u8, l, self.string)) {
                return true;
            }
        }
        return false;
    }

    /// Convert the argument string to a given type. Raises
    /// `CannotParseFlagAsPositional` if attempting to call on a flag argument.
    pub fn as(self: *const Arg, comptime T: type) CLIErrors!T {
        if (self.flag) return CLIErrors.CannotParseFlagAsPositional;
        const info = @typeInfo(T);
        const parsed: T = switch (info) {
            .Int => std.fmt.parseInt(T, self.string, 10),
            .Float => std.fmt.parseFloat(T, self.string),
            else => @compileError("Could not parse type given."),
        } catch {
            std.debug.print("{any}\n", .{self});
            return CLIErrors.CouldNotParse;
        };

        return parsed;
    }

    fn isShortFlag(self: *const Arg) bool {
        return self.flag and self.string.len == 1;
    }
};

const ArgumentType = enum {
    ShortFlag,
    LongFlag,
    Seperator,
    Positional,
    pub fn from(arg: []const u8) !ArgumentType {
        if (arg[0] == '-') {
            if (arg.len > 1) {
                if (arg.len > 2 and arg[1] == '-') return .LongFlag;
                if (std.mem.eql(u8, arg, "--")) return .Seperator;
                return .ShortFlag;
            }
            return CLIErrors.BadArgument;
        }
        return .Positional;
    }
};

/// Splits argument string into tokenized arguments. Called owns memory.
pub fn splitArgs(allocator: std.mem.Allocator, args: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    var itt = std.mem.tokenize(u8, args, " ");
    while (itt.next()) |arg| {
        try list.append(arg);
    }
    return list.toOwnedSlice();
}

pub const ArgIterator = struct {
    args: ListIterator([]const u8),
    previous: ?Arg = null,
    current: []const u8 = "",
    current_type: ArgumentType = .Positional,
    index: usize = 0,
    counter: usize = 0,

    /// Create a copy of the argument interator with all state reset.
    pub fn copy(self: *const ArgIterator) ArgIterator {
        return ArgIterator.init(self.args.data);
    }

    /// Rewind the current index by one, allowing the same argument to be
    /// parsed twice.
    pub fn rewind(self: *ArgIterator) void {
        switch (self.current_type) {
            .Positional, .LongFlag, .Seperator => self.args.index -= 1,
            .ShortFlag => {
                if (self.index == 2) {
                    // only one flag read, so need to rewind the argument too
                    self.args.index -= 1;
                    self.index = self.current.len;
                } else {
                    self.index -= 1;
                }
            },
        }
    }

    pub fn init(args: []const []const u8) ArgIterator {
        return .{ .args = ListIterator([]const u8).init(args) };
    }

    /// Get the next argument as the argument to a flag. Raises
    /// `CannotParseFlagAsPositional` if the next argument is a flag.
    /// Differs from `nextPositional` is that it does not increment the
    /// positional index.
    pub fn getValue(self: *ArgIterator) CLIErrors!Arg {
        var arg = (try self.next()) orelse return CLIErrors.TooFewArguments;
        if (arg.flag) return CLIErrors.CannotParseFlagAsPositional;
        // decrement counter as we don't actually want to count as positional
        self.counter -= 1;
        arg.index = null;
        return arg;
    }

    /// Get the next argument as the argument as a positional. Raises
    /// `CannotParseFlagAsPositional` if the next argument is a flag.
    pub fn nextPositional(self: *ArgIterator) CLIErrors!?Arg {
        const arg = (try self.next()) orelse return null;
        if (arg.flag) return CLIErrors.CannotParseFlagAsPositional;
        return arg;
    }

    /// Get the next argument as an `Arg`
    pub fn next(self: *ArgIterator) CLIErrors!?Arg {
        const arg = try self.nextImpl();
        self.previous = arg;
        return arg;
    }

    fn nextImpl(self: *ArgIterator) CLIErrors!?Arg {
        // check if we need the next argument
        if (self.index >= self.current.len) {
            self.resetArgState();
            // get next argument
            const next_arg = self.args.next() orelse return null;
            self.current_type = try ArgumentType.from(next_arg);
            self.current = next_arg;
        }

        switch (self.current_type) {
            .Seperator => return self.next(),
            .ShortFlag => {
                // skip the leading minus
                if (self.index == 0) self.index = 1;
                // read the next character
                self.index += 1;
                return .{
                    .string = self.current[self.index - 1 .. self.index],
                    .flag = true,
                };
            },
            .LongFlag => {
                self.index = self.current.len;
                return .{
                    .string = self.current[2..],
                    .flag = true,
                };
            },
            .Positional => {
                self.index = self.current.len;
                self.counter += 1;
                return .{
                    .flag = false,
                    .string = self.current,
                    .index = self.counter,
                };
            },
        }
    }

    fn resetArgState(self: *ArgIterator) void {
        self.current_type = .Positional;
        self.current = "";
        self.index = 0;
    }

    fn isAny(self: *ArgIterator, short: ?u8, long: []const u8) !bool {
        var nested = ArgIterator.init(self.args.data);
        while (try nested.next()) |arg| {
            if (arg.is(short, long)) return true;
        }
        return false;
    }

    pub fn throwUnknownFlag(self: *const ArgIterator) !void {
        const arg: Arg = self.previous.?;
        if (arg.isShortFlag()) {
            try throwError(CLIErrors.UnknownFlag, "-{s}", .{arg.string});
        } else {
            try throwError(CLIErrors.UnknownFlag, "--{s}", .{arg.string});
        }
    }

    pub fn throwBadArgument(
        self: *const ArgIterator,
        comptime msg: []const u8,
    ) !void {
        const arg: Arg = self.previous.?;
        try throwError(CLIErrors.BadArgument, msg ++ ": '{s}'", .{arg.string});
    }

    pub fn throwTooManyArguments(self: *const ArgIterator) !void {
        const arg = self.previous.?;
        try throwError(
            CLIErrors.TooManyArguments,
            "argument '{s}' is too much",
            .{arg.string},
        );
    }

    pub fn assertNoArguments(self: *ArgIterator) !void {
        if (try self.next()) |arg| {
            if (arg.flag) {
                return try self.throwUnknownFlag();
            } else return try self.throwTooManyArguments();
        }
    }
};

fn fromString(alloc: std.mem.Allocator, args: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    errdefer list.deinit();
    var itt = std.mem.tokenizeAny(u8, args, " =");

    while (itt.next()) |item| try list.append(item);
    return list.toOwnedSlice();
}

fn argIs(arg: Arg, comptime expected: Arg) !void {
    try std.testing.expectEqual(expected.flag, arg.flag);
    try std.testing.expectEqual(expected.index, arg.index);
    try std.testing.expectEqualStrings(expected.string, arg.string);
}

test "argument iteration" {
    const args = try fromString(
        std.testing.allocator,
        "-tf -k hello --thing=that 1 2 5.0 -q",
    );
    defer std.testing.allocator.free(args);
    var argitt = ArgIterator.init(args);
    try std.testing.expect(try argitt.isAny(null, "thing"));
    try std.testing.expect((try argitt.isAny(null, "thinhjhhg")) == false);
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "t" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "f" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "k" });
    try argIs(try argitt.getValue(), .{ .flag = false, .string = "hello" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "thing" });
    try argIs(try argitt.getValue(), .{ .flag = false, .string = "that" });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "1", .index = 1 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "2", .index = 2 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "5.0", .index = 3 });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "q" });
}

const ExtendedHelpItem = struct {
    arg: []const u8,
    help: []const u8,
};

const ExtendedHelpOptions = struct {
    description: []const u8 = "",
};

const LEFT_PADDING = 4;
const CENTRE_PADDING = 22;
const HELP_LEN = 48;
const HELP_INDENT = 2;

/// Comptime function for constructing extended help strings. Also used to
/// inform the shell autocompletion.
pub fn extendedHelp(
    comptime items: []const ExtendedHelpItem,
    comptime opts: ExtendedHelpOptions,
) []const u8 {
    // for future use
    _ = opts;
    @setEvalBranchQuota(5000);
    comptime var help: []const u8 = "";

    inline for (items) |item| {
        help = help ++
            " " ** LEFT_PADDING ++
            item.arg ++
            " " ** (CENTRE_PADDING - item.arg.len);

        help = help ++ comptimeWrap(item.help, .{
            .left_pad = LEFT_PADDING + CENTRE_PADDING,
            .continuation_indent = HELP_INDENT,
            .column_limit = HELP_LEN,
        });

        help = help ++ "\n";
    }

    return help ++ "\n";
}

pub const WrappingOptions = struct {
    left_pad: usize = 0,
    continuation_indent: usize = 0,
    column_limit: usize = 80,
};

/// Wrap a string over a number of lines in a comptime context
pub fn comptimeWrap(comptime text: []const u8, comptime opts: WrappingOptions) []const u8 {
    comptime var out: []const u8 = "";
    comptime var line_len: usize = 0;
    // comptime var itt = std.mem.split(u8, item.help, " ");
    comptime var itt = std.mem.split(u8, text, " ");

    // so we can reinsert the spaces correctly we do the first word first
    if (itt.next()) |first_word| {
        out = out ++ first_word;
        line_len += first_word.len;
    }
    // followed by all others words
    while (itt.next()) |word| {
        out = out ++ " ";
        line_len += word.len;
        if (line_len > opts.column_limit) {
            out = out ++
                "\n" ++
                " " ** (opts.left_pad + opts.continuation_indent);
            line_len = opts.continuation_indent;
        }
        out = out ++ word;
    }

    return out;
}
