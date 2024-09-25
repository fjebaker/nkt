const std = @import("std");
const termui = @import("termui");
const fuzzig = @import("fuzzig");
const tracy = @import("tracy.zig");

const color = @import("colors.zig");
const utils = @import("utils.zig");
const ThreadMap = @import("threads.zig").ThreadMap;

const MatchIterator = utils.Iterator(usize);

/// The maximum needle length for fuzzy finder search queries.
pub const NEEDLE_MAX = 128;

fn writeHighlightMatched(
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
pub const FuzzyFinder = fuzzig.Ascii;

/// Searcher structure prototype. Uses `Item` in the field of each result, so
/// that user can pass context backwards and forwards to relate the search
/// result back to a specific item.
///
/// The searcher is designed to have a set number of string over which it
/// searches with a variable needle. It is not designed to have the space of
/// haystacks changed over its lifetime.
pub fn Searcher(comptime Item: type) type {
    return struct {
        const Self = @This();

        /// The result type used by the searcher
        pub const Result = struct {
            /// The user context item
            item: *const Item,
            /// The string that the needle was matched to (i.e. haystack).
            string: []const u8,
            /// The indexes into that string where the needle matched
            matches: []usize,
            num_matches: usize,
            /// The score of this match, or null if it did not match
            score: ?i32,

            /// Compares scores, returns true if `lhs` has a lower score that
            /// `rhs`
            pub fn scoreLessThan(lhs: Result, rhs: Result) bool {
                return Result.lessThan({}, lhs, rhs);
            }

            /// Compares scores, returns true if `lhs` has an equal score to
            /// `rhs`
            pub fn scoreEqual(lhs: Result, rhs: Result) bool {
                if (rhs.score == null) {
                    return lhs.score == null;
                } else if (lhs.score == null) {
                    return false;
                }
                return lhs.score.? == rhs.score.?;
            }

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

        /// A list of all of the results, along with metadata about the search
        /// query
        pub const ResultList = struct {
            results: []Result,
            /// How long (in us)
            runtime: u64,

            /// Return only those results that have a score (i.e. drop all
            /// those that have null score). Assumes the results array is
            /// sorted in ascending order (nulls at the front).
            fn nonNull(results: []Result, runtime: u64) ResultList {
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

        const WorkClosure = struct {
            finders: []FuzzyFinder,
            needle: []const u8,

            fn work(c: *WorkClosure, result: *Result, id: usize) void {
                var t_ctx = tracy.trace(@src());
                defer t_ctx.end();

                const finder = &c.finders[id];

                const r = finder.scoreMatches(result.string, c.needle);
                result.num_matches = r.matches.len;
                // copy from thread local back to the shared store
                std.mem.copyBackwards(usize, result.matches, r.matches);

                result.score = r.score;
            }
        };

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

            return .{
                .result_buffer = results,
                .max_content_length = max_content_length,
            };
        }

        heap: std.heap.ArenaAllocator,
        items: []const Item,
        result_buffer: []Result,
        closure: *WorkClosure,
        pool: *ThreadMap,
        previous_needle: []const u8 = "",
        num_previous_matches: usize = 0,

        /// Initialize a finder
        pub fn initItems(
            allocator: std.mem.Allocator,
            items: []const Item,
            strings: []const []const u8,
            opts: fuzzig.Ascii.Options,
        ) !Self {
            var heap = std.heap.ArenaAllocator.init(allocator);
            errdefer heap.deinit();
            const info = try initResultsBuffer(heap.allocator(), items, strings);

            // TODO: read from an env var or configuration for the maximum
            // number of threads
            const n_threads = std.Thread.getCpuCount() catch 1;

            // allocate the thread pool used to map the search function onto
            // all of the string
            var threads = try ThreadMap.init(
                allocator,
                .{ .num_threads = n_threads },
            );
            errdefer threads.deinit();

            // initialize a fuzzy finder for each thread. we need the work
            // closure to be shared by all of the threads, so we'll heap
            // allocate that to avoid taking pointers to things on the stack
            const c_ptr = try heap.allocator().create(WorkClosure);
            c_ptr.* = .{
                .finders = try heap.allocator().alloc(
                    FuzzyFinder,
                    n_threads,
                ),
                .needle = "",
            };

            var mod_opts = opts;

            // modify the options with new penalizing scores
            mod_opts.scores.score_gap_extension = -2;
            mod_opts.scores.score_gap_start = -4;

            for (c_ptr.finders) |*finder| {
                finder.* = try FuzzyFinder.init(
                    heap.allocator(),
                    info.max_content_length,
                    128,
                    mod_opts,
                );
            }

            return .{
                .heap = heap,
                .items = items,
                .pool = threads,
                .closure = c_ptr,
                .result_buffer = info.result_buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.heap.deinit();
            self.pool.deinit();
            self.* = undefined;
        }

        fn getSearchSlice(self: *Self, needle: []const u8) []Result {
            if (self.num_previous_matches == 0) return self.result_buffer;

            // if the new needle is the old needle with some new characters, no
            // need to research everything, just search in the previous results
            if (std.mem.startsWith(u8, needle, self.previous_needle)) {
                const start = self.result_buffer.len - self.num_previous_matches;
                return self.result_buffer[start..];
            }
            return self.result_buffer;
        }

        /// Search for needle in all strings
        pub fn search(self: *Self, needle: []const u8) !ResultList {
            tracy.frameMarkNamed("search");
            var t_ctx = tracy.trace(@src());
            defer t_ctx.end();

            const res_slice = self.getSearchSlice(needle);

            // prime the threads with the new search string
            self.closure.needle = needle;

            var timer = try std.time.Timer.start();
            try self.pool.map(
                Result,
                res_slice,
                self.closure,
                WorkClosure.work,
                .{},
            );
            self.pool.blockUntilDone();
            const runtime = timer.lap();

            self.previous_needle = needle;
            {
                var t2_ctx = tracy.traceNamed(@src(), "sorting");
                defer t2_ctx.end();
                std.sort.heap(Result, res_slice, {}, Result.lessThan);
            }

            const res_list = ResultList.nonNull(res_slice, runtime);
            self.num_previous_matches = res_list.results.len;

            return res_list;
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

/// Used to split larger strings (e.g. file contents) into many smaller strings
/// to be fuzzy searched through.
///
/// The chunks are split by newlines, so that each paragraph becomes an
/// individually searched chunk.
pub const ChunkMachine = struct {
    /// The key used to later reconstruct which string, and where it that
    /// string, a chunk came from
    pub const ChunkIndex = struct {
        index: usize,
        start: usize,
        end: usize,
        line_no: usize,
    };

    pub const SearcherType = Searcher(ChunkIndex);
    pub const Result = SearcherType.Result;
    pub const ResultList = SearcherType.ResultList;

    const ItemList = std.ArrayList(ChunkIndex);
    const StringList = std.ArrayList([]const u8);

    /// the original strings used to generate the chunks
    values: StringList,
    /// a descriptor of each chunk
    item_list: ItemList,
    /// the chunks themselves
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
            if (std.mem.trim(u8, line, " \t").len < 3) continue;

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

    /// Get the full string associated with a given chunk
    pub fn getValueFromChunk(self: *const ChunkMachine, key: ChunkIndex) []const u8 {
        std.debug.assert(key.index < self.values.items.len);
        return self.values.items[key.index];
    }

    /// Get a searcher for the chunks. Searcher will use the passed allocator
    /// instead of the ChunkMachine's allocator
    pub fn searcher(
        self: *ChunkMachine,
        alloc: std.mem.Allocator,
        opts: fuzzig.Ascii.Options,
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
    ///
    /// Note: the value is not copied, so the caller must ensure the lifetime
    /// of the value string is longer that the lifetime of the ChunkMachine
    pub fn add(self: *ChunkMachine, value: []const u8) !void {
        const index = self.values.items.len;
        try self.values.append(value);
        try self.addChunksToIndex(value, index);
    }

    /// Initialize the chunk machine
    pub fn init(alloc: std.mem.Allocator) ChunkMachine {
        return .{
            .values = StringList.init(alloc),
            .item_list = ItemList.init(alloc),
            .chunks = StringList.init(alloc),
        };
    }

    pub fn deinit(self: *ChunkMachine) void {
        self.values.deinit();
        self.item_list.deinit();
        self.chunks.deinit();
        self.* = undefined;
    }

    /// Get the number of items (chunks) currently stored.
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
