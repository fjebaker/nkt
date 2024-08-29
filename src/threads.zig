const std = @import("std");

/// Used to parallelize work over threads using a batching algorith
pub const ThreadMap = struct {
    pub const Options = struct {
        num_threads: usize,
    };

    pool: std.Thread.Pool,
    allocator: std.mem.Allocator,
    sync: std.Thread.Mutex = .{},
    shared_index: usize = 0,
    opts: Options,
    wg: std.Thread.WaitGroup = .{},

    /// Join all threads, cleanup allocated resources, and destroy self.
    pub fn deinit(self: *ThreadMap) void {
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    /// Initialize a new thread map
    pub fn init(
        allocator: std.mem.Allocator,
        opts: Options,
    ) !*ThreadMap {
        const ptr = try allocator.create(ThreadMap);
        errdefer allocator.destroy(ptr);

        ptr.allocator = allocator;
        ptr.opts = opts;
        try ptr.pool.init(
            .{
                .allocator = allocator,
                .n_jobs = opts.num_threads,
            },
        );

        return ptr;
    }

    pub const MapOptions = struct {
        chunk_size: usize = 128,
    };

    /// In-place map: maps the function `f` onto each element of `slice`
    pub fn map(
        self: *ThreadMap,
        comptime T: type,
        slice: []T,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), *T, usize) void,
        opts: MapOptions,
    ) !void {
        const Context = @TypeOf(ctx);

        const Wrapper = struct {
            parent: *ThreadMap,
            user_ctx: Context,
            data: []T,
            index: usize = 0,
            chunk_size: usize,
            id: usize,

            fn getNextIndex(w: @This()) usize {
                w.parent.sync.lock();
                defer w.parent.sync.unlock();
                const i = w.parent.shared_index;
                w.parent.shared_index += w.chunk_size;
                return i;
            }

            fn doWork(w: @This()) void {
                var ind = w.index;
                while (ind <= w.data.len) {
                    const s = w.data[ind..@min(w.data.len, ind + w.chunk_size)];
                    for (s) |*v| f(w.user_ctx, v, w.id);
                    ind = w.getNextIndex();
                }

                w.parent.wg.finish();
            }
        };

        self.shared_index = 0;
        self.wg = .{};
        for (0..self.opts.num_threads) |i| {
            self.wg.start();

            const w: Wrapper = .{
                .parent = self,
                .user_ctx = ctx,
                .data = slice,
                .index = self.shared_index,
                .chunk_size = opts.chunk_size,
                .id = i,
            };
            self.shared_index += opts.chunk_size;
            try self.pool.spawn(Wrapper.doWork, .{w});
        }
    }

    /// Blocks the calling thread until the work group has finished
    pub fn blockUntilDone(self: *ThreadMap) void {
        self.pool.waitAndWork(&self.wg);
    }
};
