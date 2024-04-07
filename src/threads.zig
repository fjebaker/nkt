const std = @import("std");

pub fn ThreadPool(
    comptime RetType: type,
    comptime Ctx: type,
    comptime WorkFunc: fn (*RetType, *Ctx) void,
) type {
    const Shared = struct { output: []RetType };
    const ThreadLocal = struct {
        const Self = @This();

        shared: *Shared,
        ctx: *Ctx,

        // lock for synchronizing work
        lock: *std.Thread.Mutex,

        // lock for synchronizing communications
        comm_lock: *std.Thread.Mutex,

        cont_barrier: *std.Thread.Condition,

        // used to communicate from the workers to the main thread
        main_barrier: *std.Thread.Condition,

        work_available: *bool,

        completed: *usize,
        index: *usize,

        fn getIndex(s: Self) usize {
            s.lock.lock();
            defer s.lock.unlock();
            const index = s.index.*;
            s.index.* += 1;
            return index;
        }

        fn markComplete(s: Self) void {
            s.lock.lock();
            defer s.lock.unlock();
            s.completed.* += 1;
            s.main_barrier.signal();
        }

        fn getReturnSlot(s: Self) ?*RetType {
            const index = s.getIndex();
            if (index >= s.shared.output.len) return null;
            return &s.shared.output[index];
        }

        fn workAvailable(s: Self) bool {
            s.comm_lock.lock();
            defer s.comm_lock.unlock();
            s.cont_barrier.wait(s.comm_lock);
            return s.work_available.*;
        }

        inline fn doWork(s: Self) void {
            while (s.getReturnSlot()) |rptr| {
                WorkFunc(rptr, s.ctx);
            }
            s.markComplete();
        }

        fn worker(s: Self) void {
            s.doWork();
            while (s.workAvailable()) {
                s.doWork();
            }
        }
    };

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        threads: []?std.Thread,

        shared: *Shared,

        ctxs: []Ctx,
        index: usize = 0,
        completed: usize = 0,
        workload_length: usize = 0,
        work_available: bool = true,

        index_lock: std.Thread.Mutex = .{},
        comm_lock: std.Thread.Mutex = .{},
        main_barrier: std.Thread.Condition = .{},
        cont_barrier: std.Thread.Condition = .{},

        pub fn deinit(self: *Self) void {
            self.join();
            self.allocator.free(self.threads);
            self.allocator.free(self.ctxs);
            self.allocator.destroy(self.shared);
            self.* = undefined;
        }

        fn join(self: *Self) void {
            {
                // this should always be thread safe, but better safe than sorry
                self.comm_lock.lock();
                defer self.comm_lock.unlock();
                self.work_available = false;
            }
            // signal all to end
            self.cont_barrier.broadcast();
            for (self.threads) |thread| {
                if (thread) |t| t.join();
            }
        }

        fn makeThreadLocal(
            self: *Self,
            ctx: *Ctx,
        ) ThreadLocal {
            const tl: ThreadLocal = .{
                .ctx = ctx,
                .lock = &self.index_lock,
                .comm_lock = &self.comm_lock,
                .cont_barrier = &self.cont_barrier,
                .main_barrier = &self.main_barrier,
                .work_available = &self.work_available,
                .completed = &self.completed,
                .index = &self.index,
                .shared = self.shared,
            };
            return tl;
        }

        fn spawnThreads(self: *Self) !void {
            for (self.threads, self.ctxs) |*thread, *ctx| {
                if (thread.* != null) @panic("Thread already launched!");
                const tl = self.makeThreadLocal(ctx);
                thread.* = try std.Thread.spawn(
                    .{},
                    ThreadLocal.worker,
                    .{tl},
                );
            }
        }

        /// Map the thread function for each item in the output
        pub fn map(self: *Self, outputs: []RetType) !void {
            {
                // this should always be thread safe, but better safe than sorry
                self.index_lock.lock();
                defer self.index_lock.unlock();

                self.index = 0;
                self.completed = 0;
                self.shared.output = outputs;
            }

            if (self.threads[0] == null) {
                try self.spawnThreads();
            } else {
                self.comm_lock.lock();
                defer self.comm_lock.unlock();
                self.cont_barrier.broadcast();
            }

            self.workload_length = outputs.len;
        }

        pub fn blockUntilDone(self: *Self) void {
            {
                self.comm_lock.lock();
                defer self.comm_lock.unlock();
                while (self.completed != self.threads.len) {
                    self.main_barrier.wait(&self.comm_lock);
                }
            }
        }

        pub fn init(allocator: std.mem.Allocator, num_threads: usize) !Self {
            const threads = try allocator.alloc(?std.Thread, num_threads);
            errdefer allocator.free(threads);
            for (threads) |*t| t.* = null;

            const ctxs = try allocator.alloc(Ctx, num_threads);
            errdefer allocator.free(ctxs);

            return .{
                .allocator = allocator,
                .threads = threads,
                .ctxs = ctxs,
                .shared = try allocator.create(Shared),
            };
        }
    };
}
