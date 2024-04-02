const std = @import("std");
const cli = @import("cli.zig");
const time = @import("topology/time.zig");
const Tasklist = @import("topology/Tasklist.zig");
const Root = @import("topology/Root.zig");
const tags = @import("topology/tags.zig");

pub const Error = error{
    HashTooLong,
    InvalidHash,
};

/// Returns true if haystack contains needle
pub fn contains(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |item| {
        const is_contained = switch (@typeInfo(T)) {
            .Vector, .Pointer, .Array => std.mem.eql(
                std.meta.Elem(T),
                item,
                needle,
            ),
            else => item == needle,
        };
        if (is_contained) return true;
    }
    return false;
}

/// Get the name of a collection from its path
pub fn inferCollectionName(s: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, s, '/') orelse return null;
    if (std.mem.eql(u8, s[0..3], "dir")) return s[4..end];
    unreachable; // todo
}

/// Parse a due string to time
pub fn parseDue(time_now: time.Time, due: ?[]const u8) !?time.Time {
    const d = due orelse return null;
    return try time.parseTimelike(time_now, d);
}

/// Parse importance string
pub fn parseImportance(importance: ?[]const u8) !Tasklist.Importance {
    const imp = importance orelse
        return .Low;
    return try Tasklist.Importance.parseFromString(imp);
}

/// Ensures that only the fields in `fields` are not null.
pub fn ensureOnly(
    comptime T: type,
    args: T,
    comptime fields: []const []const u8,
    collection_type: []const u8,
) !void {
    const allowed: []const []const u8 = fields ++ .{collection_type};
    inline for (@typeInfo(T).Struct.fields) |f| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, f.name)) {
                break;
            }
        } else {
            switch (@typeInfo(f.type)) {
                .Optional => {
                    if (@field(args, f.name) != null) {
                        try cli.throwError(
                            error.AmbiguousSelection,
                            "Cannot provide '{s}' argument when selecting '{s}'",
                            .{ f.name, collection_type },
                        );
                        unreachable;
                    }
                },
                .Bool => {
                    if (@field(args, f.name) == true) {
                        try cli.throwError(
                            error.AmbiguousSelection,
                            "Cannot provide '{s}' argument when selecting '{s}'",
                            .{ f.name, collection_type },
                        );
                        unreachable;
                    }
                },
                else => {},
            }
        }
    }
}

/// Returns true if all characters in `string` return `true` in `f`.
pub fn allAre(comptime f: fn (u8) bool, string: []const u8) bool {
    for (string) |c| {
        if (!f(c)) return false;
    }
    return true;
}

/// Check if all characters are numeric
pub fn allNumeric(string: []const u8) bool {
    return allAre(std.ascii.isDigit, string);
}

/// Check if all characters are alpha numeric
pub fn allAlphanumeric(string: []const u8) bool {
    return allAre(std.ascii.isAlphanumeric, string);
}

/// Check if all characters are alpha numeric or a minus (tag-like names)
pub fn allAlphanumericOrMinus(string: []const u8) bool {
    const S = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '-';
        }
    };
    return allAre(S.f, string);
}

/// Get the abbreviated hash of a key, selecting `len` bytes
pub fn getMiniHash(key: u64, len: u6) u64 {
    const shift = (16 - len) * 4;
    return key >> shift;
}

test "mini hashes" {
    try std.testing.expectEqual(getMiniHash(0xabc123abc1231111, 3), 0xabc);
}

/// Create a u64 hash of a type.
pub fn hash(comptime T: type, key: T) u64 {
    if (T == []const u8) {
        return std.hash.Wyhash.hash(0, key);
    }

    if (comptime std.meta.hasUniqueRepresentation(T)) {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
    } else {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        return hasher.final();
    }
}

/// Get the type of a tag struct in a union
pub fn TagType(comptime T: type, comptime name: []const u8) type {
    const fields = @typeInfo(T).Union.fields;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("No field named " ++ name);
}

/// A helper for creating iterable slices
pub fn ListIterator(comptime T: type) type {
    return struct {
        data: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .data = items };
        }

        /// Get the next item in the slice. Returns `null` if no items left.
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

/// Parses all tags using `tags.parseInlineWithAdditional`, and validates the
/// tags against the taglist in `Root`. Caller owns the memory.
pub fn parseAndAssertValidTags(
    allocator: std.mem.Allocator,
    root: *Root,
    text: ?[]const u8,
    additional: []const []const u8,
) ![]tags.Tag {
    const parsed_tags = try tags.parseInlineWithAdditional(allocator, text, additional);
    errdefer allocator.free(parsed_tags);

    var tl = try root.getTagDescriptorList();
    if (tl.findInvalidTags(parsed_tags)) |invalid_tag| {
        try cli.throwError(
            error.InvalidTag,
            "@{s} is not a known tag",
            .{invalid_tag.name},
        );
        unreachable;
    }

    return parsed_tags;
}

/// Check if error is in the error set
pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).ErrorSet.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(anyerror, e.name);
    }
    return null;
}

/// Check if a string is an alias of a command
pub fn isAlias(
    comptime field: std.builtin.Type.UnionField,
    name: []const u8,
) bool {
    if (@hasDecl(field.type, "alias")) {
        inline for (@field(field.type, "alias")) |alias| {
            if (std.mem.eql(u8, alias, name)) return true;
        }
    }
    return false;
}

pub fn Iterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }

        /// Get the next item and advance the counter.
        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const item = self.items[self.index];
            self.index += 1;
            return item;
        }

        /// Get at the next item without advancing the counter.
        pub fn peek(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            return self.items[self.index];
        }
    };
}

pub fn ReverseIterator(comptime T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .items = items };
        }
        pub fn next(self: *@This()) ?T {
            if (self.index >= self.items.len) return null;
            const i = self.items.len - self.index - 1;
            const item = self.items[i];
            self.index += 1;
            return item;
        }
    };
}

pub const UriSlice = struct {
    start: usize,
    end: usize,
    uri: std.Uri,
};

pub fn findUriFromColon(text: []const u8, index_of_colon: usize) ?UriSlice {
    const start = index_of_colon;
    // too few characters remaining
    if (!(text.len >= start + 3))
        return null;

    const lookahead = text[start + 1 .. start + 3];

    if (!std.mem.eql(u8, lookahead, "//"))
        return null;
    // get the word boundaries
    const begin = b: {
        var i: usize = start - 1;
        while (i >= 0) {
            const c = text[i];
            if (std.ascii.isWhitespace(c) or c == '(') break :b i + 1;
            if (i == 0) break :b 0;
            i -= 1;
        }
        unreachable;
    };
    const end = std.mem.indexOfAnyPos(u8, text, start + 2, " )\n\t\r") orelse
        text.len;
    const slice = text[begin..end];
    const uri = std.Uri.parse(slice) catch {
        return null;
    };
    return .{
        .start = begin,
        .end = end,
        .uri = uri,
    };
}

/// Return the absolute difference between two values
pub fn absDiff(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (a > b) return a - b;
    return b - a;
}

// needs revisting below here
// vvvvvvvvvvvvvvvvvvvvvvvvvv

// pub const DateError = error{DateStringTooShort};

// pub const Time = time.datetime.Time;
// pub const Date = time.datetime.Datetime;

// pub fn dateFromMs(ms: u64) Date {
//     return Date.fromTimestamp(@intCast(ms));
// }

// pub fn msFromDate(date: Date) u64 {
//     return @intCast(date.toTimestamp());
// }

// pub fn ListMixin(comptime Self: type, comptime T: type) type {
//     return struct {
//         pub fn initSize(alloc: std.mem.Allocator, N: usize) !Self {
//             const items = try alloc.alloc(T, N);
//             return .{ .allocator = alloc, .items = items };
//         }

//         pub fn initOwned(alloc: std.mem.Allocator, items: []T) Self {
//             if (@hasDecl(Self, "_init")) {
//                 @call(.auto, @field(Self, "_init"), .{ alloc, items });
//             } else {
//                 return .{ .allocator = alloc, .items = items };
//             }
//         }

//         pub fn deinit(self: *Self) void {
//             if (@hasDecl(Self, "_deinit")) {
//                 @call(.auto, @field(Self, "_deinit"), .{self});
//             } else {
//                 self.allocator.free(self.items);
//                 self.* = undefined;
//             }
//         }

//         pub fn reverse(self: *Self) void {
//             std.mem.reverse(T, self.items);
//         }
//     };
// }

// pub fn List(comptime T: type) type {
//     return struct {
//         const Self = @This();

//         allocator: std.mem.Allocator,
//         items: []T,

//         pub usingnamespace ListMixin(Self, T);
//     };
// }

// pub fn SortableList(comptime T: type, comptime lessThan: anytype) type {
//     return struct {
//         const Self = @This();

//         allocator: std.mem.Allocator,
//         items: []T,

//         pub usingnamespace ListMixin(Self, T);

//         pub fn sort(self: *Self) void {
//             std.sort.insertion(T, self.items, {}, lessThan);
//         }
//     };
// }

// fn dateSort(_: void, lhs: Date, rhs: Date) bool {
//     return (lhs.toUnixMilli() < rhs.toUnixMilli());
// }

// pub const DateList = SortableList(Date, dateSort);

// const TIMEZONE = time.timezones.Europe.London;
// const EQUINOX = d: {
//     var date = Date.fromDate(2023, 10, 29) catch @compileError("Equinox: bad date");
//     date.time.hour = 2;
//     break :d date;
// };

// pub fn adjustTimezone(date: Date) Date {
//     if (date.lt(EQUINOX)) return date.shiftHours(1);
//     return date.shiftTimezone(&TIMEZONE);
// }

// pub fn now() u64 {
//     return @intCast(std.time.milliTimestamp());
// }

// pub fn endOfDay(day: Date) Date {
//     const second_to_day_end = std.time.s_per_day - @as(
//         i64,
//         @intFromFloat(day.time.toSeconds()),
//     );
//     const day_end = day.shiftSeconds(second_to_day_end - 1);
//     return day_end;
// }

// pub fn toDate(string: []const u8) !Date {
//     if (string.len < 10) return DateError.DateStringTooShort;
//     const year = try std.fmt.parseInt(u16, string[0..4], 10);
//     // months and day start at zero
//     const month = try std.fmt.parseInt(u8, string[5..7], 10);
//     const day = try std.fmt.parseInt(u8, string[8..10], 10);

//     return newDate(year, month, day);
// }

// pub fn areSameDay(d1: Date, d2: Date) bool {
//     return d1.years == d2.years and d1.months == d2.months and d1.days == d2.days;
// }

// pub fn newDate(year: u16, month: u8, day: u8) !Date {
//     return try Date.fromDate(year, month, day);
// }

// pub fn formatDateBuf(date: Date) ![10]u8 {
//     const t_date = adjustTimezone(date);
//     var buf: [10]u8 = undefined;
//     var bufstream = std.io.fixedBufferStream(&buf);
//     try bufstream.writer().print(
//         "{d:0>4}-{d:0>2}-{d:0>2}",
//         .{ t_date.date.year, t_date.date.month, t_date.date.day },
//     );
//     return buf;
// }

// pub fn formatTimeBuf(date: Date) ![8]u8 {
//     const t_date = adjustTimezone(date);
//     var buf: [8]u8 = undefined;
//     var bufstream = std.io.fixedBufferStream(&buf);
//     try bufstream.writer().print(
//         "{d:0>2}:{d:0>2}:{d:0>2}",
//         .{ t_date.time.hour, t_date.time.minute, t_date.time.second },
//     );
//     return buf;
// }

// pub fn formatDateTimeBuf(date: Date) ![19]u8 {
//     var buf: [19]u8 = undefined;

//     const date_s = try formatDateBuf(date);
//     const time_s = try formatTimeBuf(date);

//     @memcpy(buf[0..10], &date_s);
//     buf[10] = ' ';
//     @memcpy(buf[11..], &time_s);

//     return buf;
// }

// pub fn push(
//     comptime T: type,
//     allocator: std.mem.Allocator,
//     list: *[]T,
//     new: T,
// ) !*T {
//     var new_list = try allocator.alloc(T, list.len + 1);
//     for (new_list[0..list.len], list.*) |*i, j| i.* = j;
//     new_list[list.len] = new;
//     allocator.free(list.*);
//     list.* = new_list;
//     return &list.*[list.len - 1];
// }

// fn testToDateAndBack(s: []const u8) !void {
//     const date = try toDate(s);
//     const back = try formatDateBuf(date);
//     try std.testing.expectEqualSlices(u8, s, back[0..10]);
// }

// test "to date" {
//     try testToDateAndBack("2023-01-10");
//     try testToDateAndBack("2010-02-19");
//     try testToDateAndBack("2017-11-19");
// }

// test "time shift" {
//     const date = t: {
//         var d = try Date.fromDate(2023, 10, 10);
//         d.time.hour = 23;
//         d.time.minute = 13;
//         d.time.second = 0;
//         break :t d;
//     };
//     const new = adjustTimezone(date);
//     try std.testing.expectEqual(new.time.hour, 0);
//     try std.testing.expectEqual(new.date.day, 11);
// }

// pub fn moveToEnd(comptime T: type, items: []T, index: usize) void {
//     const swap = std.mem.swap;
//     for (items[index..], index + 1..) |*ptr, i| {
//         // check we're not going past the end
//         if (i == items.len) break;
//         const next_ptr = &items[i];
//         swap(T, ptr, next_ptr);
//     }
// }

// const Tag = @import("collections.zig").Tag;
// pub fn emptyTagList(allocator: std.mem.Allocator) ![]Tag {
//     return try allocator.alloc(Tag, 0);
// }

// /// Represents dot-deliniated hierarchy in note names.
// pub const Hierarchy = struct {
//     root: []const u8,
//     rest: ?[]const u8 = null,

//     pub const Error = error{InvalidHierarchy};

//     pub fn init(s: []const u8) Hierarchy {
//         const index = std.mem.indexOfScalar(u8, s, '.') orelse
//             return .{ .root = s };
//         return .{ .root = s[0..index], .rest = s[index + 1 .. s.len] };
//     }

//     pub fn child(h: Hierarchy) ?Hierarchy {
//         if (h.rest) |rest| {
//             return Hierarchy.init(rest);
//         }
//         return null;
//     }
// };

// fn testHierarchy(string: []const u8, comptime components: []const []const u8) !void {
//     var list = std.ArrayList([]const u8).init(std.testing.allocator);
//     defer list.deinit();

//     var root = Hierarchy.init(string);
//     try list.append(root.root);

//     while (root.child()) |child| {
//         root = child;
//         try list.append(root.root);
//     }

//     for (list.items, components) |acc, exp| {
//         try std.testing.expectEqualStrings(exp, acc);
//     }
// }

// test "hierarchy" {
//     try testHierarchy("notes.thing.other", &.{ "notes", "thing", "other" });
//     try testHierarchy("notes", &.{"notes"});
// }
