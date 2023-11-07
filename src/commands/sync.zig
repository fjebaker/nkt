const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Self = @This();

pub const help = "Sync root directory to remote git repository";

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    if (try itt.next()) |_| {
        return cli.CLIErrors.TooManyArguments;
    }

    return self;
}

const Git = struct {
    mem: std.heap.ArenaAllocator,
    root_dir: []const u8,
    env_map: std.process.EnvMap,

    pub fn init(alloc: std.mem.Allocator, root_dir: []const u8) !Git {
        var mem = std.heap.ArenaAllocator.init(alloc);
        errdefer mem.deinit();

        var temp_alloc = mem.allocator();
        var env_map = try std.process.getEnvMap(temp_alloc);

        return .{
            .mem = mem,
            .root_dir = root_dir,
            .env_map = env_map,
        };
    }

    fn setupProcess(git: *Git, proc: *std.ChildProcess) void {
        proc.env_map = &git.env_map;
        proc.cwd = git.root_dir;

        proc.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        proc.stdout_behavior = std.ChildProcess.StdIo.Inherit;
        proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;
    }

    pub fn addAllCommit(git: *Git, message: []const u8) !void {
        var add_proc = std.ChildProcess.init(
            &.{ "git", "add", "." },
            git.mem.child_allocator,
        );
        git.setupProcess(&add_proc);
        _ = try add_proc.spawnAndWait();

        var commit_proc = std.ChildProcess.init(
            &.{ "git", "commit", "-m", message },
            git.mem.child_allocator,
        );
        git.setupProcess(&commit_proc);
        _ = try commit_proc.spawnAndWait();
    }

    pub fn push(git: *Git) !void {
        var push_proc = std.ChildProcess.init(
            &.{ "git", "push", "origin", "main" },
            git.mem.child_allocator,
        );
        git.setupProcess(&push_proc);
        _ = try push_proc.spawnAndWait();
    }

    pub fn deinit(git: *Git) void {
        git.mem.deinit();
        git.* = undefined;
    }
};

pub fn run(
    _: *Self,
    state: *State,
    _: anytype,
) !void {
    var git = try Git.init(state.allocator, state.fs.root_path);
    defer git.deinit();

    try git.addAllCommit("nkt sync backup");
    try git.push();
}
