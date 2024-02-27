const std = @import("std");
const Time = @import("types.zig").Time;
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
