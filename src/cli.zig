const std = @import("std");
const selections = @import("cli/selections.zig");

pub const Selection = selections.Selection;
pub const SelectedCollection = selections.SelectedCollection;

pub const SelectionError = error{
    AmbiguousSelection,
    InvalidSelection,
    NoSuchDirectory,
    NoSuchJournal,
    NoSuchEntry,
    UnknownCollection,
};

pub const find = selections.find;

fn Iterator(comptime T: type) type {
    return struct {
        data: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .data = items };
        }
        pub fn next(self: *@This()) ?T {
            if (self.index < self.data.len) {
                const v = self.data[self.index];
                self.index += 1;
                return v;
            }
            return null;
        }
    };
}

pub const CLIErrors = error{
    BadArgument,
    CouldNotParse,
    DuplicateFlag,
    NoValueGiven,
    TooFewArguments,
    TooManyArguments,
    UnknownFlag,
};

pub const Arg = struct {
    string: []const u8,

    flag: bool = false,
    index: ?usize = null,

    pub fn is(self: *const Arg, short: ?u8, long: ?[]const u8) bool {
        if (short) |s| {
            if (s == self.string[0]) {
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

    pub fn as(self: *const Arg, comptime T: type) CLIErrors!T {
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

pub const ArgIterator = struct {
    args: Iterator([]const u8),
    current: []const u8 = "",
    current_type: ArgumentType = .Positional,
    index: usize = 0,
    counter: usize = 0,

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
        return .{ .args = Iterator([]const u8).init(args) };
    }

    pub fn getValue(self: *ArgIterator) CLIErrors!Arg {
        var arg = (try self.next()) orelse return CLIErrors.TooFewArguments;
        if (arg.flag) return CLIErrors.BadArgument;
        // decrement counter as we don't actually want to count as positional
        self.counter -= 1;
        arg.index = null;
        return arg;
    }

    pub fn next(self: *ArgIterator) CLIErrors!?Arg {
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

test "submodules" {
    _ = selections;
}

test "argument iteration" {
    var args = try fromString(
        std.testing.allocator,
        "-tf -k hello --thing=that 1 2 3 4 5.0 -q",
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
}
