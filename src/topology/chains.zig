const std = @import("std");
const time = @import("time.zig");
const Time = time.Time;
const tags = @import("tags.zig");
const Tag = tags.Tag;

pub const Error = error{ChainAlreadyComplete};

pub const Chain = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    details: ?[]const u8 = null,
    active: bool = true,
    created: Time,
    // dates that were completed
    completed: []Time = &.{},
    tags: []Tag = &.{},
};

pub const ChainList = struct {
    chains: []Chain = &.{},
    mem: std.heap.ArenaAllocator,

    pub fn init(mem: std.heap.ArenaAllocator, chains: []Chain) ChainList {
        return .{
            .mem = mem,
            .chains = chains,
        };
    }

    /// Get the index of a `Chain` by name or alias `name`. Returns null if no
    /// match
    pub fn getIndexByNameOrAlias(self: *ChainList, name: []const u8) ?usize {
        for (0.., self.chains) |i, c| {
            if (std.mem.eql(u8, c.name, name)) return i;
            if (c.alias) |alias| if (std.mem.eql(u8, alias, name)) return i;
        }
        return null;
    }

    /// Add completion time `Time` to the chain at index `i`
    pub fn addCompletionTime(self: *ChainList, i: usize, t: Time) !void {
        var list = std.ArrayList(Time).fromOwnedSlice(
            self.mem.allocator(),
            self.chains[i].completed,
        );
        try list.append(t);
        self.chains[i].completed = try list.toOwnedSlice();
    }

    /// Checks whether the chain has been marked as complete for today
    pub fn isChainComplete(self: *const ChainList, i: usize) bool {
        const chain = self.chains[i];
        if (chain.completed.len == 0) return false;

        const latest = chain.completed[chain.completed.len - 1];
        const today = time.Time.now().toDate();

        return today.date.eql(latest.toDate().date);
    }

    /// Add a new `Chain` to the chain list.
    pub fn addChain(self: *ChainList, chain: Chain) !void {
        for (self.chains) |c| {
            // check no same name
            if (std.mem.eql(u8, chain.name, c.name)) return error.DuplicateItem;
            if (chain.alias) |alias| {
                if (c.alias) |a| {
                    // check no same alias
                    if (std.mem.eql(u8, alias, a)) return error.DuplicateItem;
                    // check name not existing alias
                    if (std.mem.eql(u8, chain.name, a)) return error.DuplicateItem;
                }
                // check alias not an existing name
                if (std.mem.eql(u8, alias, c.name)) return error.DuplicateItem;
            }
        }

        // pre-conditions passed, add the chain
        var list = std.ArrayList(Chain).fromOwnedSlice(
            self.mem.allocator(),
            self.chains,
        );

        try list.append(chain);
        self.chains = try list.toOwnedSlice();
    }

    /// Serialize for saving to disk. Caller own the memory
    pub fn serialize(self: *ChainList, allocator: std.mem.Allocator) ![]const u8 {
        return try std.json.stringifyAlloc(
            allocator,
            ChainWrapper{ .chains = self.chains },
            .{ .whitespace = .indent_4 },
        );
    }

    pub fn deinit(self: *ChainList) void {
        self.mem.deinit();
        self.* = undefined;
    }
};

const ChainWrapper = struct {
    chains: []Chain,
};

pub fn readChainList(allocator: std.mem.Allocator, content: []const u8) !ChainList {
    var mem = std.heap.ArenaAllocator.init(allocator);
    errdefer mem.deinit();

    const chains = try std.json.parseFromSliceLeaky(
        ChainWrapper,
        mem.allocator(),
        content,
        .{ .allocate = .alloc_always },
    );

    return ChainList.init(mem, chains.chains);
}
