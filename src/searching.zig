const std = @import("std");
const termui = @import("termui");
const fuzzig = @import("fuzzig");

const color = @import("colors.zig");
const utils = @import("utils.zig");
const ThreadPoolT = @import("threads.zig").ThreadPool;

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
                    if (lhs.score == null) return true;
                    return false;
                }
                if (lhs.score == null) {
                    return true;
                }
                return lhs.score.? < rhs.score.?;
            }

            fn getMatched(r: Result) []const usize {
                return r.matches[0..r.num_matches];
            }

            /// Print the matches highlighted in the search string with some
            /// context lines and a maximal width
            pub fn printMatched(
                r: Result,
                writer: anytype,
                ctx: usize,
                maxlen: usize,
            ) !void {
                const matches = r.getMatched();
                var start = matches[0] -| ctx;
                const last_match_index = matches[matches.len - 1];
                var end = @min(
                    start + maxlen,
                    @min(last_match_index + ctx, r.string.len),
                );

                const f = color.RED;

                if (start > 0) {
                    try color.DIM.write(writer, "...", .{});
                    start += 3;
                }
                if (end < r.string.len) {
                    end -|= 3;
                }

                const slice = r.string[start..end];

                var m_i: usize = 0;
                for (slice, start..) |c, i| {
                    if (m_i < matches.len and matches[m_i] == i) {
                        try f.write(writer, "{c}", .{c});
                        m_i += 1;
                    } else {
                        try writer.writeByte(c);
                    }
                }

                if (end < r.string.len) {
                    try color.DIM.write(writer, "...", .{});
                }
            }
        };

        pub const ResultList = struct {
            results: []const Result,
            runtime: u64,

            fn nonNull(results: []const Result, runtime: u64) ResultList {
                var index: usize = 0;
                for (results, 0..) |r, i| {
                    if (r.score != null) {
                        index = i;
                        break;
                    }
                } else return .{ .results = results, .runtime = runtime };
                return .{ .results = results[index..], .runtime = runtime };
            }
        };

        const ThreadCtx = struct {
            finder: fuzzig.Ascii,
            needle: []const u8 = "",
        };

        const ThreadPool = ThreadPoolT(Result, ThreadCtx, threadWork);

        fn threadWork(result: *Result, ctx: *ThreadCtx) void {
            const r = ctx.finder.scoreMatches(result.string, ctx.needle);
            result.num_matches = r.matches.len;
            @memcpy(result.matches[0..result.num_matches], r.matches);
            result.score = r.score;
        }

        heap: std.heap.ArenaAllocator,
        items: []const Item,
        result_buffer: []Result,
        pool: ThreadPool,
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
                res.score = 0;

                max_content_length = @max(max_content_length, string.len);
            }
            return .{ .result_buffer = results, .max_content_length = max_content_length };
        }

        /// Initialize a finder
        pub fn initItems(
            allocator: std.mem.Allocator,
            items: []const Item,
            strings: []const []const u8,
            opts: fuzzig.AsciiOptions,
        ) !Self {
            var heap = std.heap.ArenaAllocator.init(allocator);
            errdefer heap.deinit();
            const info = try initResultsBuffer(heap.allocator(), items, strings);

            const n_threads = std.Thread.getCpuCount() catch 1;

            var threads = try ThreadPool.init(allocator, n_threads);
            errdefer threads.deinit();

            for (threads.ctxs) |*ctx| {
                ctx.finder = try fuzzig.Ascii.init(
                    heap.allocator(),
                    info.max_content_length,
                    128,
                    opts,
                );
                ctx.needle = "";
            }

            return .{
                .heap = heap,
                .items = items,
                .pool = threads,
                .result_buffer = info.result_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit();
            self.pool.deinit();
            self.* = undefined;
        }

        /// Search for needle in all strings
        pub fn search(self: *Self, needle: []const u8) !ResultList {
            for (self.pool.ctxs) |*ctx| ctx.needle = needle;

            var timer = try std.time.Timer.start();
            try self.pool.map(self.result_buffer);
            self.pool.blockUntilDone();

            self.previous_needle = needle;

            std.sort.insertion(Result, self.result_buffer, {}, Result.lessThan);
            const runtime = timer.lap();
            return ResultList.nonNull(self.result_buffer, runtime);
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
        .{},
    );
    defer searcher.deinit();

    const res_list = try searcher.search("ae");

    try std.testing.expectEqual(res_list.results.len, 3);
    try std.testing.expectEqual(res_list.results[0].item.*, 3);
    try std.testing.expectEqual(res_list.results[1].item.*, 0);
    try std.testing.expectEqual(res_list.results[2].item.*, 1);
}
