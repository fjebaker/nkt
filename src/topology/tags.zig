const std = @import("std");
const time = @import("time.zig");
const Time = time.Time;
const utils = @import("../utils.zig");
const colors = @import("../colors.zig");

pub const Error = error{
    InvalidTag,
    MissingTagDescriptors,
    TagNotLowercase,
};

pub const Tag = struct {
    pub const Descriptor = struct {
        name: []const u8,
        created: Time,
        color: colors.Color,

        /// Does the descritor describe the tag, as in, do they share the same
        /// name?
        pub fn isDescriptorOf(self: Descriptor, tag: Tag) bool {
            return std.mem.eql(u8, self.name, tag.name);
        }

        /// Create a new tag with a random color
        pub fn new(name: []const u8) Descriptor {
            return .{
                .name = name,
                .created = time.timeNow(),
                .color = colors.randomColor(),
            };
        }
    };

    name: []const u8,
    added: Time,

    /// Test if two tags are equal or not. Only checks the name.
    pub fn eql(self: Tag, t: Tag) bool {
        return std.mem.eql(u8, self.name, t.name);
    }
};

const TagDescriptorWrapper = struct {
    tags: []const Tag.Descriptor,
};

pub const DescriptorList = struct {
    tags: []Tag.Descriptor,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        descriptors: []const Tag.Descriptor,
    ) !DescriptorList {
        var list = std.ArrayList(Tag.Descriptor).init(allocator);
        defer list.deinit();
        errdefer for (list.items) |item| {
            allocator.free(item.name);
        };

        for (descriptors) |d| {
            try list.append(.{
                .name = try allocator.dupe(u8, d.name),
                .created = d.created,
                .color = d.color,
            });
        }

        return .{
            .tags = try list.toOwnedSlice(),
            .allocator = allocator,
        };
    }

    /// Add a new `Tag.Descriptor` to the descritor list. Makes a copy of the
    /// name.
    pub fn addTagDescriptor(self: *DescriptorList, tag: Tag.Descriptor) !void {
        for (self.tags) |t| {
            if (std.mem.eql(u8, t.name, tag.name)) {
                return error.DuplicateItem;
            }
        }

        var new_tag = tag;
        new_tag.name = try self.allocator.dupe(u8, tag.name);

        var list = std.ArrayList(Tag.Descriptor).fromOwnedSlice(
            self.allocator,
            self.tags,
        );
        try list.append(new_tag);
        self.tags = try list.toOwnedSlice();
    }

    /// Serialize for saving to disk. Caller owns the memory
    pub fn serialize(
        self: *const DescriptorList,
        allocator: std.mem.Allocator,
        _: time.TimeZone,
    ) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        return try std.json.stringifyAlloc(
            allocator,
            TagDescriptorWrapper{ .tags = self.tags },
            .{ .whitespace = .indent_4 },
        );
    }

    pub fn deinit(self: *DescriptorList) void {
        for (self.tags) |*t| self.allocator.free(t.name);
        self.allocator.free(self.tags);
        self.* = undefined;
    }

    /// Check the tag is described by one of the tag descriptors in the
    /// `DescriptorList`. Returns `true` if tag is valid.
    pub fn isValidTag(self: *const DescriptorList, tag: Tag) bool {
        for (self.tags) |d| {
            if (d.isDescriptorOf(tag)) return true;
        }
        return false;
    }

    /// Like `isValidTag` except for a slice of `Tag`s, returning the first
    /// invalid tag. Returns `null` if all tags are valid.
    pub fn findInvalidTags(self: *const DescriptorList, taglist: []const Tag) ?Tag {
        // TODO: assert no duplicates
        for (taglist) |tag| {
            if (!self.isValidTag(tag)) {
                return tag;
            }
        }
        return null;
    }
};

/// Returns true if one of the tags in `mine` is present in `theirs`.
pub fn hasUnion(mine: []const Tag, theirs: []const Tag) bool {
    for (mine) |m| {
        for (theirs) |t| {
            if (m.eql(t)) return true;
        }
    }
    return false;
}

/// Parse tags that are inline with the text such as "hello @world".  Returns a
/// list of tags. Caller owns the memory.  The tags do not copy strings from
/// the input text, so the input text must outlive the tags.
/// Does not validate the tags are valid.
pub fn parseInlineTags(
    allocator: std.mem.Allocator,
    text: []const u8,
    now: Time,
) ![]Tag {
    const positions = try parseInlineTagPositions(allocator, text);
    defer allocator.free(positions);

    var tags = try std.ArrayList(Tag).initCapacity(allocator, positions.len);
    defer tags.deinit();

    var name_itt = TagNameIterator{ .positions = positions, .string = text };
    while (name_itt.next()) |name| {
        const tag: Tag = .{ .added = now, .name = name };
        tags.appendAssumeCapacity(tag);
    }

    return tags.toOwnedSlice();
}

/// Parse the given `content` JSON into a `DescriptorList`
pub fn readTagDescriptors(
    allocator: std.mem.Allocator,
    content: []const u8,
) !DescriptorList {
    var parsed = try std.json.parseFromSlice(
        TagDescriptorWrapper,
        allocator,
        content,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    return try DescriptorList.init(allocator, parsed.value.tags);
}

/// Returns the name of the tag if the string is a @tag, else null. Will throw
/// a `TagNotLowercase` error if the tag is not lowercase.
pub fn getTagString(string: []const u8) error{TagNotLowercase}!?[]const u8 {
    if (string[0] == '@') {
        var itt = utils.ListIterator(u8).init(string[1..]);
        const end = try getTagStringIterated(&itt);
        return string[1..end];
    }
    return null;
}

fn getTagStringIterated(itt: *utils.ListIterator(u8)) error{TagNotLowercase}!usize {
    while (itt.next()) |c| {
        switch (c) {
            'a'...'z', '.', '-' => {},
            'A'...'Z' => return Error.TagNotLowercase,
            else => return itt.index,
        }
    }
    return itt.index + 1;
}

fn testIsTagString(string: []const u8, comptime name: ?[]const u8) !void {
    const parsed = try getTagString(string);
    try std.testing.expectEqualDeep(name, parsed);
}

test "tag strings" {
    try testIsTagString("@hello", "hello");
    try testIsTagString("@hello   ", "hello");
    try testIsTagString("@hello 123", "hello");
    try testIsTagString("hello", null);
    try testIsTagString("@thing.another.thing", "thing.another.thing");
    try testIsTagString("@kebab-case", "kebab-case");
    try std.testing.expectError(
        Error.TagNotLowercase,
        testIsTagString("@ohNo", null),
    );
}

/// Indexes denoting the position of the scope within the string
pub const InlinePosition = struct {
    start: usize,
    end: usize,
    pub fn ofString(pos: InlinePosition, string: []const u8) []const u8 {
        return string[pos.start..pos.end];
    }
};

/// Parse all the of positions of inline tags in a string. Returns an array of
/// `InlinePosition`. Caller owns the memory.
pub fn parseInlineTagPositions(allocator: std.mem.Allocator, string: []const u8) ![]InlinePosition {
    var positions = std.ArrayList(InlinePosition).init(allocator);
    defer positions.deinit();

    var itt = utils.ListIterator(u8).init(string);

    var escaped: bool = false;
    while (itt.next()) |c| {
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and c == '@') { // at the beginning of a tag
            const start = itt.index - 1;
            const end = try getTagStringIterated(&itt);
            try positions.append(
                .{ .start = start, .end = end - 1 },
            );
        }
        escaped = false;
    }

    return try positions.toOwnedSlice();
}

/// An iterator for iterating over `InlinePosition` arrays and extracting tag
/// names
pub const TagNameIterator = struct {
    string: []const u8,
    positions: []const InlinePosition,
    index: usize = 0,

    /// Get the next tag name in the string else return `null`.
    pub fn next(itt: *TagNameIterator) ?[]const u8 {
        if (itt.index < itt.positions.len) {
            const pos = itt.positions[itt.index];
            itt.index += 1;
            // cut off @
            return pos.ofString(itt.string)[1..];
        }
        return null;
    }

    /// Flush all names into a list. Caller owns the memory
    pub fn flush(
        itt: *TagNameIterator,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var list = try std.ArrayList([]const u8).initCapacity(
            allocator,
            itt.positions.len,
        );
        defer list.deinit();

        while (itt.next()) |name| {
            list.appendAssumeCapacity(name);
        }

        return try list.toOwnedSlice();
    }
};

fn testInlineTagPositions(
    string: []const u8,
    comptime names: []const []const u8,
    comptime positions: []const InlinePosition,
) !void {
    var alloc = std.testing.allocator;
    const pos = try parseInlineTagPositions(alloc, string);
    defer alloc.free(pos);

    var name_itt = TagNameIterator{ .positions = pos, .string = string };
    const tag_names = try name_itt.flush(alloc);
    defer alloc.free(tag_names);

    try std.testing.expectEqualDeep(positions, pos);
    try std.testing.expectEqualDeep(names, tag_names);
}

test "inline position parsing" {
    try testInlineTagPositions(
        "123 @world 123",
        &.{"world"},
        &.{
            .{ .start = 4, .end = 10 },
        },
    );
    try testInlineTagPositions(
        "this is @something that needs to be @done",
        &.{ "something", "done" },
        &.{
            .{ .start = 8, .end = 18 },
            .{ .start = 36, .end = 41 },
        },
    );
    try testInlineTagPositions(
        "this is @something that needs to be @done!",
        &.{ "something", "done" },
        &.{
            .{ .start = 8, .end = 18 },
            .{ .start = 36, .end = 41 },
        },
    );
    try testInlineTagPositions(
        "this is something that needs to be done",
        &.{},
        &.{},
    );
    try testInlineTagPositions(
        "this is \\@something that needs to be done",
        &.{},
        &.{},
    );
}

/// Parse both inline and additional tags. Does not validate tags. Caller owns
/// memory.
pub fn parseInlineWithAdditional(
    allocator: std.mem.Allocator,
    text: ?[]const u8,
    additional_tags: []const []const u8,
) ![]Tag {
    const now = time.timeNow();

    // parse all the context tags and add them to the given tags
    const inline_tags: []Tag = if (text) |txt|
        try parseInlineTags(allocator, txt, now)
    else
        &.{};
    var all_tags = std.ArrayList(Tag).fromOwnedSlice(allocator, inline_tags);
    defer all_tags.deinit();

    for (additional_tags) |name| {
        try all_tags.append(.{ .added = now, .name = name });
    }

    return try all_tags.toOwnedSlice();
}

/// Set difference between two lists of tags. Returns all those tags in A that are not in B.
pub fn setDifference(
    allocator: std.mem.Allocator,
    list_A: []const Tag,
    list_B: []const Tag,
) ![]const Tag {
    var list = std.ArrayList(Tag).init(allocator);

    for (list_A) |t1| {
        for (list_B) |t2| {
            if (t1.eql(t2)) break;
        } else {
            try list.append(t1);
        }
    }

    return try list.toOwnedSlice();
}

test "tag difference" {
    const alloc = std.testing.allocator;

    const diff = try setDifference(
        alloc,
        &.{ .{
            .name = "A",
            .added = 0,
        }, .{
            .name = "B",
            .added = 0,
        } },
        &.{.{
            .name = "A",
            .added = 0,
        }},
    );
    defer alloc.free(diff);

    try std.testing.expectEqualDeep(
        &[_]Tag{.{
            .name = "B",
            .added = 0,
        }},
        diff,
    );
}

/// Returns the union of two tag sets. Will remove duplicate tags.
pub fn setUnion(
    allocator: std.mem.Allocator,
    list_A: []const Tag,
    list_B: []const Tag,
) ![]const Tag {
    var list = std.ArrayList(Tag).init(allocator);

    // TODO: this algorithm can be made much more efficient

    for (list_A) |t1| {
        for (list.items) |t| {
            if (t.eql(t1)) break;
        } else {
            try list.append(t1);
        }
    }

    for (list_B) |t1| {
        for (list.items) |t| {
            if (t.eql(t1)) break;
        } else {
            try list.append(t1);
        }
    }

    return try list.toOwnedSlice();
}

test "tag union" {
    const alloc = std.testing.allocator;

    const diff = try setUnion(
        alloc,
        &.{ .{
            .name = "A",
            .added = 0,
        }, .{
            .name = "B",
            .added = 0,
        } },
        &.{.{
            .name = "A",
            .added = 0,
        }},
    );
    defer alloc.free(diff);

    try std.testing.expectEqualDeep(
        &[_]Tag{ .{
            .name = "A",
            .added = 0,
        }, .{
            .name = "B",
            .added = 0,
        } },
        diff,
    );
}
