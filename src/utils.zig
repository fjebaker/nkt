const std = @import("std");
const cli = @import("cli.zig");
const time = @import("topology/time.zig");
const Tasklist = @import("topology/Tasklist.zig");
const Root = @import("topology/Root.zig");
const tags = @import("topology/tags.zig");
const Item = @import("abstractions.zig").Item;

/// Check if an optional is equal to a value orelse return null
pub fn isElseNull(a: anytype, v: ?@TypeOf(a)) ?bool {
    if (v) |value| {
        return value == a;
    }
    return null;
}

/// Prompt the user yes or no and return their choice. Default no.
pub fn promptNo(
    allocator: std.mem.Allocator,
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
) !bool {
    try writer.print(fmt ++ "\nyes/[no]: ", args);
    const choice = try issuePrompt(allocator, writer);
    return choice orelse false;
}
/// Prompt the user yes or no and return their choice. Defaults yes.
pub fn promptYes(
    allocator: std.mem.Allocator,
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
) !bool {
    try writer.print(fmt ++ "\n[yes]/no: ", args);
    const choice = try issuePrompt(allocator, writer);
    return choice orelse true;
}

pub const GetAllItemsOpts = struct {
    directory: ?bool = null,
    journal: ?bool = null,
    tasklist: ?bool = null,

    fn allNull(self: GetAllItemsOpts) bool {
        return self.directory == null and
            self.journal == null and
            self.tasklist == null;
    }

    fn with(self: GetAllItemsOpts, comptime field: []const u8) bool {
        const f = @field(self, field);
        if (f) |v| return v;
        return false;
    }
};

/// Get all Items in the Root
pub fn getAllItems(
    allocator: std.mem.Allocator,
    root: *Root,
    opts: GetAllItemsOpts,
) ![]Item {
    var list = std.ArrayList(Item).init(allocator);
    defer list.deinit();

    // pre-allocate some memory
    try list.ensureUnusedCapacity(1000);

    const all = opts.allNull();

    if (all or opts.with("directory")) {
        for (root.getAllDescriptor(.CollectionDirectory)) |d| {
            const dir = (try root.getDirectory(d.name)).?;
            for (dir.getInfo().notes) |note| {
                try list.append(
                    .{ .Note = .{ .directory = dir, .note = note } },
                );
            }
        }
    }

    if (all or opts.with("tasklist")) {
        for (root.getAllDescriptor(.CollectionTasklist)) |d| {
            const tlist = (try root.getTasklist(d.name)).?;
            for (tlist.getInfo().tasks) |task| {
                try list.append(
                    .{ .Task = .{ .tasklist = tlist, .task = task } },
                );
            }
        }
    }

    if (all or opts.with("journal")) {
        for (root.getAllDescriptor(.CollectionJournal)) |d| {
            var journal = (try root.getJournal(d.name)).?;
            for (journal.getInfo().days) |day| {
                const entries = try journal.getEntries(day);
                for (entries) |e| {
                    try list.append(
                        .{ .Entry = .{ .journal = journal, .day = day, .entry = e } },
                    );
                }
            }
        }
    }

    return list.toOwnedSlice();
}

fn issuePrompt(
    allocator: std.mem.Allocator,
    writer: anytype,
) !?bool {
    var stdin = std.io.getStdIn().reader();
    const input = try stdin.readUntilDelimiterOrEofAlloc(
        allocator,
        '\n',
        1024,
    );
    defer if (input) |inp| allocator.free(inp);

    if (input) |inp| {
        _ = try writer.writeAll("\n");
        if (std.mem.eql(u8, inp, "yes")) return true;
        if (std.mem.eql(u8, inp, "no")) return false;
    }
    return null;
}

/// Get the index pointing to the end of the current slice returned by a
/// standard library split iterator
pub fn getSplitIndex(itt: std.mem.SplitIterator(u8, .scalar)) usize {
    if (itt.index) |ind| {
        return ind - 1;
    } else {
        return itt.buffer.len;
    }
}

pub const LineWindowIterator = struct {
    pub const LineSlice = struct {
        line_no: usize,
        slice: []const u8,
    };
    itt: std.mem.SplitIterator(u8, .scalar),
    chunk: ?std.mem.WindowIterator(u8) = null,

    size: usize,
    stride: usize,
    current_line: usize = 0,

    end_index: usize = 0,

    fn getNextWindow(w: *LineWindowIterator) ?[]const u8 {
        if (w.chunk) |*chunk| {
            const line = chunk.next();
            if (line) |l| {
                w.end_index += l.len;
                return l;
            }
        }
        return null;
    }

    fn package(w: *LineWindowIterator, line: []const u8) LineSlice {
        return .{ .line_no = w.current_line, .slice = line };
    }

    /// Returns the next `LineSlice`
    pub fn next(w: *LineWindowIterator) ?LineSlice {
        if (w.getNextWindow()) |line| {
            return w.package(line);
        }

        while (w.itt.next()) |section| {
            w.end_index = getSplitIndex(w.itt) - section.len;
            w.chunk = std.mem.window(u8, section, w.size, w.stride);
            if (w.getNextWindow()) |line| {
                const pkg = w.package(line);
                w.current_line += 1;
                return pkg;
            }
        }
        return null;
    }
};

pub fn lineWindow(text: []const u8, size: usize, stride: usize) LineWindowIterator {
    const itt = std.mem.splitScalar(u8, text, '\n');
    return .{ .itt = itt, .size = size, .stride = stride };
}

pub const Error = error{
    HashTooLong,
    InvalidHash,
};

/// Returns true if haystack contains needle
pub fn contains(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |item| {
        const is_contained = switch (@typeInfo(T)) {
            .vector, .pointer, .array => std.mem.eql(
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
    inline for (@typeInfo(T).@"struct".fields) |f| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, f.name)) {
                break;
            }
        } else {
            switch (@typeInfo(f.type)) {
                .optional => {
                    if (@field(args, f.name) != null) {
                        return cli.throwError(
                            error.AmbiguousSelection,
                            "Cannot provide '{s}' argument when selecting '{s}'",
                            .{ f.name, collection_type },
                        );
                    }
                },
                .bool => {
                    if (@field(args, f.name) == true) {
                        return cli.throwError(
                            error.AmbiguousSelection,
                            "Cannot provide '{s}' argument when selecting '{s}'",
                            .{ f.name, collection_type },
                        );
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
    const fields = @typeInfo(T).@"union".fields;
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

/// Split a string into tokens.
pub fn split(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    var itt = std.mem.tokenizeAny(u8, text, "\n\r\t =");
    while (itt.next()) |tkn| {
        try list.append(tkn);
    }

    return list.toOwnedSlice();
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
        return cli.throwError(
            error.InvalidTag,
            "@{s} is not a known tag",
            .{invalid_tag.name},
        );
    }

    return parsed_tags;
}

/// Check if error is in the error set
pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).error_set.?) |e| {
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

/// Test if a string is equal to another string or its plural.
/// If plural is not given, will simlpy check if an `s` is appended.
pub fn stringEqualOrPlural(
    s: []const u8,
    expected: []const u8,
    plural: ?[]const u8,
) bool {
    const is_singular = std.mem.eql(u8, s[0..expected.len], expected);
    if (s.len == expected.len and is_singular) return true;
    if (plural) |p| {
        return std.mem.eql(u8, s, p);
    } else {
        return is_singular and s.len == expected.len + 1 and s[s.len - 1] == 's';
    }
}

test "plural compare" {
    try std.testing.expect(stringEqualOrPlural("days", "day", null));
}
