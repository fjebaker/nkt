const std = @import("std");
const Time = @import("time.zig").Time;
const colors = @import("../colors.zig");

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

pub const Error = error{TagNotLowercase};

/// name of the tag if it is, else null. Will throw a `TagNotLowercase` error
/// if the tag is not lowercase.
pub fn isTagString(string: []const u8) error{TagNotLowercase}!?[]const u8 {
    if (string[0] == '@') {
        for (string[1..], 1..) |c, end| {
            switch (c) {
                'a'...'z', '.', '-' => {},
                'A'...'Z' => return Error.TagNotLowercase,
                else => return string[1 .. end - 1],
            }
        }
        return string[1..];
    }
    return null;
}

fn testIsTagString(string: []const u8, comptime name: ?[]const u8) !void {
    const parsed = try isTagString(string);
    try std.testing.expectEqualDeep(name, parsed);
}

test "tag strings" {
    try testIsTagString("@hello", "hello");
    try testIsTagString("hello", null);
    try testIsTagString("@thing.another.thing", "thing.another.thing");
    try testIsTagString("@kebab-case", "kebab-case");
    try std.testing.expectError(
        Error.TagNotLowercase,
        testIsTagString("@ohNo", null),
    );
}
