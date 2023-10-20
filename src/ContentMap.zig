const std = @import("std");

const Self = @This();

const ContentHashMap = std.StringHashMap([]const u8);

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

pub fn put(self: *Self, key: []const u8, content: []const u8) !void {
    var alloc = self.mem.allocator();
    const owned_content = alloc.dupe(u8, content);

    try self.putMove(self, key, owned_content);
}

pub fn putMove(self: *Self, key: []const u8, content: []const u8) !void {
    try self.content_map.put(key, content);
}

pub fn get(self: *Self, key: []const u8) ?[]const u8 {
    return self.content_map.get(key);
}

pub fn deinit(self: *Self) void {
    self.mem.deinit();
    self.* = undefined;
}
