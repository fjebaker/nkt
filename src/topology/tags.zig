const std = @import("std");
const Time = @import("time.zig").Time;
const utils = @import("../utils.zig");
const colors = @import("../colors.zig");

pub const Error = error{
    MissingTagDescriptors,
    TagNotLowercase,
};

pub const Tag = struct {
    pub const Descriptor = struct {
        name: []const u8,
        created: Time,
        color: colors.Color,
    };

    name: []const u8,
    added: Time,
};

const TagDescriptorWrapper = struct {
    tags: []Tag.Descriptor,
};

pub const DescriptorList = struct {
    tags: []Tag.Descriptor = &.{},
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

    /// Add a new `Tag.Descriptor` to the descritor list.
    pub fn addTagDescriptor(self: *DescriptorList, tag: Tag.Descriptor) !void {
        for (self.tags) |t| {
            if (std.mem.eql(u8, t.name, tag.name)) {
                return error.DuplicateItem;
            }
        }

        var list = std.ArrayList(Tag.Descriptor).fromOwnedSlice(
            self.allocator,
            self.tags,
        );
        try list.append(tag);
        self.tags = try list.toOwnedSlice();
    }

    /// Serialize for saving to disk. Caller owns the memory
    pub fn serialize(self: *const DescriptorList, allocator: std.mem.Allocator) ![]const u8 {
        return try std.json.stringifyAlloc(
            allocator,
            TagDescriptorWrapper{ .tags = self.tags },
            .{ .whitespace = .indent_4 },
        );
    }

    pub fn deinit(self: *DescriptorList) void {
        for (self.tags) |*t| {
            self.allocator.free(t.name);
        }
        self.* = undefined;
    }

    // /// Parse tags that are inline with the text such as "hello @world".
    // /// Returns a list of tags. Caller owns the memory.
    // pub fn parseInlineTags(self: *DescriptorList, allocator: std.mem.Allocator, text: []const u8) ![]Tag {

    // }
};

pub fn readTagDescriptors(
    allocator: std.mem.Allocator,
    content: []const u8,
) !DescriptorList {
    var parsed = try std.json.parseFromSlice(
        TagDescriptorWrapper,
        allocator,
        content,
        .{},
    );
    defer parsed.deinit();
    return try DescriptorList.init(allocator, parsed.value.tags);
}

/// name of the tag if it is, else null. Will throw a `TagNotLowercase` error
/// if the tag is not lowercase.
pub fn isTagString(string: []const u8) error{TagNotLowercase}!?[]const u8 {
    if (string[0] == '@') {
        var itt = utils.ListIterator(u8).init(string[1..]);
        const end = try isTagStringIterated(&itt);
        return string[1..end];
    }
    return null;
}

fn isTagStringIterated(itt: *utils.ListIterator(u8)) error{TagNotLowercase}!usize {
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
    const parsed = try isTagString(string);
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

    while (itt.next()) |c| {
        if (c == '@') { // at the beginning of a tag
            const start = itt.index - 1;
            const end = try isTagStringIterated(&itt);
            try positions.append(
                .{ .start = start, .end = end - 1 },
            );
        }
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
}
