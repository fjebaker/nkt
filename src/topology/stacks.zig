const std = @import("std");
const abstractions = @import("../abstractions.zig");
const utils = @import("../utils.zig");
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

    pub fn new(name: []const u8) Stack {
        const today = time.Time.now();
        return .{
            .name = name,
            .items = &.{},
            .created = today,
            .modified = today,
        };
    }
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

    /// Add a new `Stack` to the stack list.
    pub fn addStack(self: *StackList, stack: Stack) !void {
        for (self.stacks) |s| {
            if (std.mem.eql(u8, s.name, stack.name)) return error.DuplicateItem;
        }

        // pre-conditions passed, add the stack
        var list = std.ArrayList(Stack).fromOwnedSlice(
            self.mem.allocator(),
            self.stacks,
        );

        try list.append(stack);
        self.stacks = try list.toOwnedSlice();
    }

    /// Get a pointer to a `Stack` from a name. Returns `null` if no such
    /// `Stack` exists.
    pub fn getStackPtr(self: *StackList, name: []const u8) ?*Stack {
        for (self.stacks) |*s| {
            if (std.mem.eql(u8, s.name, name)) {
                return s;
            }
        }
        return null;
    }

    /// Add an item to a `Stack`.
    pub fn addItemToStack(
        self: *StackList,
        stack: *Stack,
        item: abstractions.Item,
    ) !void {
        const allocator = self.mem.allocator();
        const descr: ItemDescriptor = .{
            .collection = item.getCollectionType(),
            .parent = item.getCollectionName(),
            .name = try item.getName(allocator),
        };

        var list = std.ArrayList(ItemDescriptor).fromOwnedSlice(
            allocator,
            stack.items,
        );
        // TODO: this needs reworking to avoid invalidating the pointer if the
        // append fails
        defer list.deinit();
        try list.insert(0, descr);
        stack.items = try list.toOwnedSlice();
    }

    /// Pop an item from the `Stack`, removing it entirely. Returns `null` if
    /// no such index exists.
    pub fn popAt(
        _: *const StackList,
        stack: *Stack,
        index: usize,
    ) ?ItemDescriptor {
        if (stack.items.len <= index) return null;
        if (index > 0) {
            for (1..index) |j| {
                const i = j - index;
                const a = &stack.items[i];
                const b = &stack.items[i - 1];
                std.mem.swap(ItemDescriptor, a, b);
            }
        }
        const descr = stack.items[0];
        stack.items = stack.items[1..];
        return descr;
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
