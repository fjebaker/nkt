const std = @import("std");

const utils = @import("utils.zig");
const farbe = @import("farbe");
const ListIterator = utils.ListIterator;

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
pub fn throwError(err: anyerror, comptime fmt: []const u8, args: anytype) !void {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = @errorName(err);

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

    pub fn throwTooFewArguments(
        _: *const ArgIterator,
        missing_arg_name: []const u8,
    ) !void {
        try throwError(
            CLIErrors.TooFewArguments,
            "missing argument '{s}'",
            .{missing_arg_name},
        );
    }

    /// Throw a general unknown argument error. To be used when it doesn't
    /// matter what the argument was, it was just unwanted.  Throw `UnknownFlag`
    /// if the last argument was a flag, else throw a `BadArgument` error.
    pub fn throwUnknown(self: *const ArgIterator) !void {
        const arg: Arg = self.previous.?;
        if (arg.flag) {
            try self.throwUnknownFlag();
        } else {
            try self.throwBadArgument("unknown argument");
        }
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

/// Argument wrapper for generating help strings and parsing
pub const ArgumentDescriptor = struct {
    /// Argument name. Can be either the name itself or a flag Short flags
    /// should just be `-f`, long flags `--flag`, and short and long
    /// `-f/--flag`
    arg: []const u8,

    /// Help string
    help: []const u8,

    /// Is a required argument
    required: bool = false,

    /// Should be parsed by the helper
    parse: bool = true,
};

/// For future use
pub const ExtendedHelpOptions = struct {
    // description: []const u8 = "",
};

pub const ArgumentError = error{MalformedName};

const LEFT_PADDING = 4;
const CENTRE_PADDING = 26;
const HELP_LEN = 48;
const HELP_INDENT = 2;

const ArgTypeInfo = union(enum) {
    ShortFlag: struct {
        name: []const u8,
        required: bool,
        with_value: bool = false,
    },
    LongFlag: struct {
        name: []const u8,
        required: bool,
        with_value: bool = false,
    },
    ShortOrLongFlag: struct {
        short: []const u8,
        long: []const u8,
        required: bool,
        with_value: bool = false,
    },
    Positional: struct {
        name: []const u8,
        required: bool,
    },

    fn getName(comptime self: ArgTypeInfo) []const u8 {
        return switch (self) {
            .ShortFlag => |f| f.name,
            .LongFlag => |f| f.name,
            .ShortOrLongFlag => |f| f.long,
            .Positional => |p| p.name,
        };
    }

    fn getRequired(comptime self: ArgTypeInfo) bool {
        return switch (self) {
            inline else => |f| f.required,
        };
    }

    fn isWithValue(comptime self: ArgTypeInfo) bool {
        return switch (self) {
            .Positional => @compileError("With value is meaningless for positional"),
            inline else => |f| f.with_value,
        };
    }

    fn isFlag(comptime self: ArgTypeInfo) bool {
        return switch (self) {
            .LongFlag, .ShortFlag, .ShortOrLongFlag => true,
            .Positional => false,
        };
    }

    fn GetType(comptime self: ArgTypeInfo) type {
        const T = if (self.isFlag() and !self.isWithValue())
            bool
        else
            []const u8;

        return if (self.getRequired()) T else ?T;
    }

    fn getDefaultValue(comptime self: ArgTypeInfo) GetType(self) {
        if (!self.getRequired()) return null;
        if (self.isFlag() and !self.isWithValue()) {
            return false;
        } else {
            return "";
        }
    }
};

fn getArgTypeInfo(arg_name: []const u8, required: bool) error{MalformedName}!ArgTypeInfo {
    var with_value: bool = false;
    // get rid of any spaces
    const arg = blk: {
        if (std.mem.indexOfScalar(u8, arg_name, ' ')) |i| {
            // accepts a value
            with_value = true;
            break :blk arg_name[0..i];
        } else {
            break :blk arg_name;
        }
    };

    if (arg[0] == '-') {
        if (arg.len == 2 and std.ascii.isAlphanumeric(arg[1])) {
            return .{
                .ShortFlag = .{
                    .name = arg[1..],
                    .required = required,
                    .with_value = with_value,
                },
            };
        } else if (arg.len > 2 and arg[2] == '/') {
            const short = arg[0..2];
            const long = arg[3..];
            if (long[0] == '-' and
                long[1] == '-' and
                utils.allAlphanumericOrMinus(long[2..]) and
                utils.allAlphanumericOrMinus(short[1..]))
            {
                return .{
                    .ShortOrLongFlag = .{
                        .short = short[1..],
                        .long = long[2..],
                        .required = required,
                        .with_value = with_value,
                    },
                };
            }
        } else if (arg[1] == '-' and utils.allAlphanumericOrMinus(arg[2..])) {
            return .{
                .LongFlag = .{
                    .name = arg[2..],
                    .required = required,
                    .with_value = with_value,
                },
            };
        }
    } else if (utils.allAlphanumeric(arg)) {
        // positional
        return .{
            .Positional = .{
                .name = arg,
                .required = required,
            },
        };
    }
    return ArgumentError.MalformedName;
}

fn testArgName(arg: []const u8, comptime expected: ArgTypeInfo) !void {
    const info = try getArgTypeInfo(arg, false);
    try std.testing.expectEqualDeep(expected, info);
}

test "arg name extraction" {
    try testArgName("hello", .{
        .Positional = .{
            .name = "hello",
            .required = false,
        },
    });
    try testArgName("-f", .{
        .ShortFlag = .{
            .name = "f",
            .required = false,
        },
    });
    try testArgName("-k/--kiss", .{
        .ShortOrLongFlag = .{
            .short = "k",
            .long = "kiss",
            .required = false,
        },
    });
    try testArgName("-k/--kiss thing", .{
        .ShortOrLongFlag = .{
            .short = "k",
            .long = "kiss",
            .required = false,
            .with_value = true,
        },
    });
    try std.testing.expectError(
        ArgumentError.MalformedName,
        getArgTypeInfo("-k//--kiss", false),
    );
    try std.testing.expectError(
        ArgumentError.MalformedName,
        getArgTypeInfo("-k//--kiss", false),
    );
}

fn makeField(
    comptime info: ArgTypeInfo,
) std.builtin.Type.StructField {
    const arg_name = info.getName();
    const T = info.GetType();
    const default = info.getDefaultValue();
    return .{
        .name = @ptrCast(arg_name),
        .type = T,
        .default_value = @ptrCast(&@as(T, default)),
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

pub fn ArgumentsHelp(comptime args: []const ArgumentDescriptor, comptime opts: ExtendedHelpOptions) type {
    _ = opts;

    comptime var parseable: []const ArgTypeInfo = &.{};
    inline for (args) |arg| {
        if (arg.parse) {
            const info = getArgTypeInfo(arg.arg, arg.required) catch
                @compileError("Could not extract name from argument for " ++ arg.arg);
            parseable = parseable ++ .{info};
        }
    }

    // create the fields for returning the arguments
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (parseable) |info| {
        fields = fields ++ .{makeField(info)};
    }

    return struct {
        pub const arguments: []const ArgumentDescriptor = args;

        pub const ParsedArguments = @Type(
            .{ .Struct = .{
                .layout = .Auto,
                .is_tuple = false,
                .fields = fields,
                .decls = &.{},
            } },
        );

        /// Write the help string for the arguments
        pub fn writeHelp(writer: anytype) !void {
            for (arguments) |arg| {
                try writer.writeByteNTimes(' ', LEFT_PADDING);
                // print the argument itself
                if (arg.required) {
                    try writer.print("<{s}>", .{arg.arg});
                } else {
                    try writer.print("[{s}]", .{arg.arg});
                }
                try writer.writeByteNTimes(' ', CENTRE_PADDING -| (arg.arg.len + 2));
                try writeWrapped(writer, arg.help, .{
                    .left_pad = LEFT_PADDING + CENTRE_PADDING,
                    .continuation_indent = HELP_INDENT,
                    .column_limit = HELP_LEN,
                });

                try writer.writeByte('\n');
            }
        }

        const Self = @This();

        itt: *ArgIterator,
        parsed: ParsedArguments = .{},

        pub fn init(itt: *ArgIterator) Self {
            return .{ .itt = itt };
        }

        /// Parses all arguments and exhausts the `ArgIterator`. Returns a
        /// structure containing all the arguments.
        pub fn parseAll(itt: *ArgIterator) !ParsedArguments {
            var self = Self.init(itt);
            while (try itt.next()) |arg| {
                switch (try self.parseArgImpl(arg)) {
                    .UnparsedFlag => try itt.throwUnknownFlag(),
                    .UnparsedPositional => try itt.throwTooManyArguments(),
                    else => {},
                }
            }
            return self.getParsed();
        }

        /// Get the parsed argument structure and validate that all required
        /// fields have values.
        pub fn getParsed(self: *const Self) !ParsedArguments {
            inline for (parseable) |p| {
                const arg_name = comptime p.getName();
                const arg = @field(self.parsed, arg_name);
                if (comptime p.getRequired()) {
                    if (arg.len == 0) {
                        try self.itt.throwTooFewArguments(arg_name);
                        unreachable;
                    }
                }
            }

            return self.parsed;
        }

        /// For debug printing only. Lists all of the fields and their values
        /// in the parsed tags structure.
        pub fn debugPrintArgs(self: *const Self) void {
            inline for (parseable) |p| {
                const arg_name = comptime p.getName();
                const arg = @field(self.parsed, arg_name);

                const ins = comptime if (p.getRequired()) "" else "?";

                if (comptime p.isFlag() and !p.isWithValue()) {
                    std.debug.print("- {s}: {" ++ ins ++ "any}\n", .{ arg_name, arg });
                } else {
                    std.debug.print("- {s}: {" ++ ins ++ "s}\n", .{ arg_name, arg });
                }
            }
            std.debug.print("\n\n", .{});
        }

        /// Parse the arguments from the argument iterator. This method is to
        /// be fed one argument at a time. Returns `false` if the argument was
        /// not used, allowing other parsing code to be used in tandem.
        pub fn parseArg(self: *Self, arg: Arg) !bool {
            return switch (try self.parseArgImpl(arg)) {
                .ParsedFlag, .ParsedPositional => true,
                .UnparsedFlag, .UnparsedPositional => false,
            };
        }

        const ParseArgOutcome = enum {
            ParsedFlag,
            ParsedPositional,
            UnparsedFlag,
            UnparsedPositional,
        };

        fn parseArgImpl(self: *Self, arg: Arg) !ParseArgOutcome {
            inline for (parseable) |p| {
                switch (p) {
                    .LongFlag => |i| if (arg.is(null, i.name)) {
                        if (i.with_value) {
                            const next = try self.itt.getValue();
                            @field(self.parsed, p.getName()) = next.string;
                        } else {
                            @field(self.parsed, p.getName()) = true;
                        }
                        return .ParsedFlag;
                    },
                    .ShortFlag => |i| if (arg.is(i.name, null)) {
                        if (i.with_value) {
                            const next = try self.itt.getValue();
                            @field(self.parsed, p.getName()) = next.string;
                        } else {
                            @field(self.parsed, p.getName()) = true;
                        }
                        return .ParsedFlag;
                    },
                    .ShortOrLongFlag => |i| if (arg.is(i.short[0], i.long)) {
                        if (i.with_value) {
                            const next = try self.itt.getValue();
                            @field(self.parsed, p.getName()) = next.string;
                        } else {
                            @field(self.parsed, p.getName()) = true;
                        }
                        return .ParsedFlag;
                    },
                    inline .Positional => |pos| if (!arg.flag) {
                        if (pos.required) {
                            if (@field(self.parsed, pos.name).len == 0) {
                                @field(self.parsed, pos.name) = arg.string;
                                return .ParsedPositional;
                            }
                        } else {
                            if (@field(self.parsed, pos.name) == null) {
                                @field(self.parsed, pos.name) = arg.string;
                                return .ParsedPositional;
                            }
                        }
                    },
                }
            }

            if (arg.flag) {
                return .UnparsedFlag;
            } else {
                return .UnparsedPositional;
            }
        }
    };
}

pub const WrappingOptions = struct {
    left_pad: usize = 0,
    continuation_indent: usize = 0,
    column_limit: usize = 70,
};

/// Wrap a string over a number of lines in a comptime context. See also
/// `writeWrapped` for a runtime version.
pub fn comptimeWrap(comptime text: []const u8, comptime opts: WrappingOptions) []const u8 {
    @setEvalBranchQuota(10000);
    comptime var out: []const u8 = "";
    comptime var line_len: usize = 0;
    comptime var itt = std.mem.splitAny(u8, text, " \n");

    // so we can reinsert the spaces correctly we do the first word first
    if (itt.next()) |first_word| {
        out = out ++ first_word;
        line_len += first_word.len;
    }
    // followed by all others words
    inline while (itt.next()) |word| {
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

/// Wrap a string over a number of lines in a comptime context.
pub fn writeWrapped(writer: anytype, text: []const u8, opts: WrappingOptions) !void {
    var line_len: usize = 0;
    var itt = std.mem.splitAny(u8, text, " \n");
    if (itt.next()) |first| {
        try writer.writeAll(first);
        line_len += first.len;
    }

    while (itt.next()) |word| {
        try writer.writeByte(' ');
        line_len += word.len;
        if (line_len > opts.column_limit) {
            try writer.writeByte('\n');
            try writer.writeByteNTimes(' ', opts.left_pad + opts.continuation_indent);
            line_len = opts.continuation_indent;
        }
        try writer.writeAll(word);
    }
}
