const std = @import("std");
const time = @import("time.zig");
const Time = time.Time;
const tags = @import("tags.zig");
const Tag = tags.Tag;

const Root = @import("Root.zig");

pub const ItemDescriptor = struct {
    /// Which collection type is this item
    collection: Root.CollectionType,
    /// What is the name of the collection type
    parent: []const u8,
    /// What is the name of this item
    name: []const u8,
    /// Associated metadata as a note
    note: []const u8 = "",
};

pub const Stack = struct {
    name: []const u8,
    items: []ItemDescriptor,
    created: Time,
    modified: Time,
};

pub const StackList = struct {
    stacks: []Stack = &.{},
    mem: std.heap.ArenaAllocator,

    pub fn init(mem: std.heap.ArenaAllocator, stacks: []Stack) StackList {
        return .{ .mem = mem, .stacks = stacks };
    }

    /// Serialize for saving to disk. Caller own the memory
    pub fn serialize(self: *StackList, allocator: std.mem.Allocator) ![]const u8 {
        return try std.json.stringifyAlloc(
            allocator,
            StackWrapper{ .stacks = self.stacks },
            .{ .whitespace = .indent_4 },
        );
    }

    pub fn deinit(self: *StackList) void {
        self.mem.deinit();
        self.* = undefined;
    }
};

const StackWrapper = struct {
    stacks: []Stack,
};

pub fn readStackList(allocator: std.mem.Allocator, content: []const u8) !StackList {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();

    const stacks = try std.json.parseFromSliceLeaky(
        StackWrapper,
        mem.allocator(),
        content,
        .{ .allocate = .alloc_always },
    );

    return StackList.init(mem, stacks.stacks);
}
