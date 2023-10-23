const std = @import("std");

pub fn ContentMap(comptime T: type) type {
    return struct {
        const Self = @This();

        const ContentHashMap = std.StringHashMap(T);

        content_map: ContentHashMap,
        mem: std.heap.ArenaAllocator,

        pub fn init(alloc: std.mem.Allocator) !Self {
            var mem = std.heap.ArenaAllocator.init(alloc);
            errdefer mem.deinit();

            return .{
                .content_map = ContentHashMap.init(alloc),
                .mem = mem,
            };
        }

        pub fn put(self: *Self, key: []const u8, content: T) !void {
            var alloc = self.mem.allocator();
            const owned_content = if (@typeInfo(T) == .Pointer)
                try alloc.dupe(@typeInfo(T).Pointer.child, content)
            else
                content;

            try self.putMove(key, owned_content);
        }

        pub fn putMove(self: *Self, key: []const u8, content: T) !void {
            try self.content_map.put(key, content);
        }

        pub fn get(self: *const Self, key: []const u8) ?T {
            return self.content_map.get(key);
        }

        pub fn deinit(self: *Self) void {
            self.content_map.deinit();
            self.mem.deinit();
            self.* = undefined;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.mem.allocator();
        }
    };
}
