const std = @import("std");
const termui = @import("termui");
const fuzzig = @import("fuzzig");

const NEEDLE_MAX = 128;

pub fn Searcher(comptime Item: type) type {
    return struct {
        const Self = @This();
        pub const Result = struct {
            item: *const Item,
            string: []const u8,
            matches: []usize,
            num_matches: usize,
            score: ?i32,

            fn lessThan(_: void, lhs: Result, rhs: Result) bool {
                if (rhs.score == null) {
                    return false;
                }
                if (lhs.score == null) {
                    return true;
                }
                return lhs.score.? < rhs.score.?;
            }
        };

        pub const ResultList = struct {
            results: []const Result,

            fn nonNull(results: []const Result) ResultList {
                var index: usize = 0;
                for (results, 0..) |r, i| {
                    if (r.score != null) {
                        index = i;
                        break;
                    }
                } else return .{ .results = results };
                return .{ .results = results[index..] };
            }
        };

        heap: std.heap.ArenaAllocator,
        items: []const Item,
        result_buffer: []Result,
        finder: fuzzig.Ascii,
        previous_needle: []const u8 = "",

        const ResultBufferInfo = struct {
            result_buffer: []Result,
            max_content_length: usize,
        };

        fn initResultsBuffer(
            allocator: std.mem.Allocator,
            items: []const Item,
            strings: []const []const u8,
        ) !ResultBufferInfo {
            const results = try allocator.alloc(Result, items.len);

            var max_content_length: usize = 0;
            // asign each result an item and a string to search in
            for (results, items, strings) |*res, *item, string| {
                res.item = item;
                res.string = string;
                // matches can only be as long as the longest needle
                res.matches = try allocator.alloc(usize, NEEDLE_MAX);
                res.num_matches = 0;
                res.score = null;

                max_content_length = @max(max_content_length, string.len);
            }
            return .{ .result_buffer = results, .max_content_length = max_content_length };
        }

        /// Initialize a finder
        pub fn initItems(
            allocator: std.mem.Allocator,
            items: []const Item,
            strings: []const []const u8,
        ) !Self {
            var heap = std.heap.ArenaAllocator.init(allocator);
            errdefer heap.deinit();
            const info = try initResultsBuffer(heap.allocator(), items, strings);
            const finder = try fuzzig.Ascii.init(
                heap.allocator(),
                info.max_content_length,
                128,
                .{},
            );
            return .{
                .heap = heap,
                .items = items,
                .finder = finder,
                .result_buffer = info.result_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit();
            self.* = undefined;
        }

        pub fn search(self: *Self, needle: []const u8) ResultList {
            for (self.result_buffer) |*result| {
                const r = self.finder.scoreMatches(result.string, needle);
                result.num_matches = r.matches.len;
                @memcpy(result.matches[0..result.num_matches], r.matches);
                result.score = r.score;
            }

            self.previous_needle = needle;

            std.sort.insertion(Result, self.result_buffer, {}, Result.lessThan);
            return ResultList.nonNull(self.result_buffer);
        }
    };
}

const TestSearch = Searcher(usize);

test "simple search" {
    const allocator = std.testing.allocator;
    const items = [_]usize{ 0, 1, 2, 3, 4, 5 };
    const strings = [_][]const u8{
        "abcdefg",
        "abc efg hij",
        "hello world",
        "this is another string",
        "aaaaaab",
        "zzzzzzzzzz",
    };

    var searcher = try TestSearch.initItems(
        allocator,
        &items,
        &strings,
    );
    defer searcher.deinit();

    const res_list = searcher.search("ae");

    try std.testing.expectEqual(res_list.results.len, 3);
    try std.testing.expectEqual(res_list.results[0].item.*, 3);
    try std.testing.expectEqual(res_list.results[1].item.*, 0);
    try std.testing.expectEqual(res_list.results[2].item.*, 1);
}
