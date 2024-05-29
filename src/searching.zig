const std = @import("std");
const termui = @import("termui");
const fuzzig = @import("fuzzig");
const tracy = @import("tracy.zig");

const color = @import("colors.zig");
const utils = @import("utils.zig");
const ThreadPoolT = @import("threads.zig").ThreadPool;

const MatchIterator = utils.Iterator(usize);

pub fn writeHighlightMatched(
    writer: anytype,
    text: []const u8,
    match_itt: *MatchIterator,
    text_offset: usize,
    match_offset: usize,
) !void {
    const f = color.RED.bold();
    for (text, text_offset..) |c, i| {
        if (match_itt.peek()) |mi| {
            if (mi + match_offset == i) {
                try f.write(writer, "{c}", .{c});
                _ = match_itt.next();
                continue;
            }
        }
        try writer.writeByte(c);
    }
}

/// Default ASCII Fuzzy Finder
pub const FuzzyFinder = fuzzig.Algorithm(
    u8,
    i32,
    .{
        .score_gap_start = -4,
        .score_gap_extension = -2,
    },
    fuzzig.AsciiOptions,
);

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

            fn getMatched(r: Result) []const usize {
                return r.matches[0..r.num_matches];
            }

            /// Print the matches highlighted in the search string with some
            /// context lines and a maximal width. Returns number of bytes
            /// written.
            pub fn printMatched(
                r: Result,
                writer: anytype,
                ctx: usize,
                maxlen: usize,
            ) !usize {
                const matches = r.getMatched();
                var start = matches[0] -| ctx;
                var end = @min(
                    start + maxlen,
                    r.string.len,
                );

                const total_length = end - start;

                if (start > 0) {
                    try color.DIM.write(writer, "...", .{});
                    start += 3;
                }
                if (end < r.string.len) {
                    end -|= 3;
                }

                const slice = r.string[start..end];

                var match_itt = MatchIterator.init(matches);
                try writeHighlightMatched(writer, slice, &match_itt, start, 0);

                if (end < r.string.len) {
                    try color.DIM.write(writer, "...", .{});
                }

                return total_length;
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
                } else return .{ .results = &.{}, .runtime = runtime };
                return .{ .results = results[index..], .runtime = runtime };
            }
        };

        const ThreadCtx = struct {
            finder: FuzzyFinder,
            needle: []const u8 = "",
        };

        const ThreadPool = ThreadPoolT(Result, ThreadCtx, threadWork);

        fn threadWork(result: *Result, ctx: *ThreadCtx) void {
            var t_ctx = tracy.trace(@src());
            defer t_ctx.end();
            const r = ctx.finder.scoreMatches(result.string, ctx.needle);
            result.num_matches = r.matches.len;
            std.mem.copyBackwards(usize, result.matches, r.matches);
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

            const match_buffer = try allocator.alloc(usize, items.len * NEEDLE_MAX);

            var max_content_length: usize = 0;
            // asign each result an item and a string to search in
            for (results, items, strings, 0..) |*res, *item, string, i| {
                res.item = item;
                res.string = string;
                // matches can only be as long as the longest needle
                res.matches = match_buffer[i * NEEDLE_MAX .. (i + 1) * NEEDLE_MAX];
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

            var threads = try ThreadPool.init(
                allocator,
                .{ .num_threads = n_threads },
            );
            errdefer threads.deinit();

            for (threads.ctxs) |*ctx| {
                ctx.finder = try FuzzyFinder.init(
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
            tracy.frameMarkNamed("search");
            var t_ctx = tracy.trace(@src());
            defer t_ctx.end();

            for (self.pool.ctxs) |*ctx| ctx.needle = needle;

            var timer = try std.time.Timer.start();
            try self.pool.map(self.result_buffer);
            self.pool.blockUntilDone();
            const runtime = timer.lap();

            self.previous_needle = needle;
            {
                var t2_ctx = tracy.traceNamed(@src(), "sorting");
                defer t2_ctx.end();
                std.sort.heap(Result, self.result_buffer, {}, Result.lessThan);
            }
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

pub const ChunkMachine = struct {
    pub const SearchKey = struct {
        index: usize,
        start: usize,
        end: usize,
        line_no: usize,
    };

    pub const SearcherType = Searcher(SearchKey);
    const ItemList = std.ArrayList(SearchKey);

    const StringList = std.ArrayList([]const u8);

    keys: StringList,
    values: StringList,
    item_list: ItemList,
    chunks: StringList,

    fn allocator(self: *ChunkMachine) std.mem.Allocator {
        return self.heap.allocator();
    }

    fn addChunksToIndex(
        self: *ChunkMachine,
        value: []const u8,
        index: usize,
    ) !void {
        var each_line = std.mem.splitScalar(u8, value, '\n');
        var line_number: usize = 0;
        while (each_line.next()) |line| {
            defer line_number += 1;
            // skip short lines
            if (std.mem.trim(u8, line, " \t").len < 4) continue;

            const end = utils.getSplitIndex(each_line);
            const start = end - line.len;

            try self.chunks.append(line);
            try self.item_list.append(.{
                .index = index,
                .start = start,
                .end = end,
                .line_no = line_number,
            });
        }
    }

    pub fn getValueFromChunk(self: *const ChunkMachine, key: SearchKey) []const u8 {
        std.debug.assert(key.index < self.values.items.len);
        return self.values.items[key.index];
    }

    pub fn getKeyFromChunk(self: *const ChunkMachine, key: SearchKey) []const u8 {
        std.debug.assert(key.index < self.keys.items.len);
        return self.keys.items[key.index];
    }

    /// Get a searcher for the chunks. Searcher will use the passed allocator
    /// instead of the ChunkMachine's allocator
    pub fn searcher(
        self: *ChunkMachine,
        alloc: std.mem.Allocator,
        opts: fuzzig.AsciiOptions,
    ) !SearcherType {
        return try SearcherType.initItems(
            alloc,
            self.item_list.items,
            self.chunks.items,
            opts,
        );
    }

    /// Add a key and value into the chunk machine. Will split the value into
    /// smaller chunks ro searching.
    pub fn add(self: *ChunkMachine, key: []const u8, value: []const u8) !void {
        const index = self.keys.items.len;
        try self.keys.append(key);
        try self.values.append(value);
        try self.addChunksToIndex(value, index);
    }

    pub fn init(alloc: std.mem.Allocator) ChunkMachine {
        return .{
            .keys = StringList.init(alloc),
            .values = StringList.init(alloc),
            .item_list = ItemList.init(alloc),
            .chunks = StringList.init(alloc),
        };
    }

    pub fn deinit(self: *ChunkMachine) void {
        self.keys.deinit();
        self.values.deinit();
        self.item_list.deinit();
        self.chunks.deinit();
        self.* = undefined;
    }

    pub fn numItems(self: *const ChunkMachine) usize {
        return self.item_list.items.len;
    }
};

pub const PreviewDisplay = struct {
    itt: utils.LineWindowIterator,

    match_itt: MatchIterator,
    match_offset: usize,
    match_line_no: usize,

    offset: usize = 0,
    last_line_no: ?usize = null,

    fn writeLineNum(p: *const PreviewDisplay, writer: anytype, i: usize) !void {
        if (p.last_line_no) |last| {
            if (i == last) {
                return try writer.writeAll("   ");
            }
        }
        try color.YELLOW.write(writer, "{d: >3}", .{i + 1});
    }

    fn getNext(p: *PreviewDisplay) ?utils.LineWindowIterator.LineSlice {
        while (p.itt.next()) |next| {
            if (next.line_no <= p.match_line_no) {
                const diff = p.match_line_no - next.line_no;
                if (diff > 4) continue;
            }
            return next;
        }
        return null;
    }

    pub fn writeNext(p: *PreviewDisplay, writer: anytype) !void {
        const next = p.getNext() orelse {
            try color.CYAN.write(writer, "~", .{});
            return;
        };

        try p.writeLineNum(writer, next.line_no);
        try writer.writeByteNTimes(' ', 1);

        try writeHighlightMatched(
            writer,
            next.slice,
            &p.match_itt,
            p.itt.end_index - next.slice.len,
            p.match_offset,
        );

        p.last_line_no = next.line_no;
    }
};

pub fn previewDisplay(
    text: []const u8,
    match_line_no: usize,
    matches: []const usize,
    match_offset: usize,
    size: usize,
) PreviewDisplay {
    return .{
        .itt = utils.lineWindow(text, size, size),
        .match_itt = MatchIterator.init(matches),
        .match_offset = match_offset,
        .match_line_no = match_line_no,
    };
}
