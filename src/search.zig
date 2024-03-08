const std = @import("std");
const FindError = error{SubProcError};

const FZF_INVOKE_COMMAND = [_][]const u8{
    "fzf",
    "--sort",
    "--phony",

    "--preview-window",
    "70%:wrap",

    "--min-height",
    "20",

    "--height",
    "40%",
};

pub const Finder = struct {
    paths: []const []const u8,
    mem: std.heap.ArenaAllocator,
    cwd: []const u8,

    pub fn init(
        alloc: std.mem.Allocator,
        cwd: []const u8,
        paths: []const []const u8,
    ) Finder {
        return .{
            .mem = std.heap.ArenaAllocator.init(alloc),
            .cwd = cwd,
            .paths = paths,
        };
    }

    pub fn deinit(state: *Finder) void {
        state.mem.deinit();
        state.* = undefined;
    }

    fn concatPaths(state: *Finder, root: []const u8) ![]const u8 {
        var alloc = state.mem.child_allocator;

        var paths = std.ArrayList([]const u8).fromOwnedSlice(
            alloc,
            try alloc.dupe([]const u8, state.paths),
        );
        defer paths.deinit();

        try paths.insert(0, root);

        return try std.mem.join(
            state.mem.allocator(),
            " ",
            paths.items,
        );
    }

    fn spawnFzfProc(state: *Finder, cmd: []const []const u8) ![]const u8 {
        var proc = std.ChildProcess.init(
            cmd,
            state.mem.child_allocator,
        );

        const alloc = state.mem.allocator();

        var env_map = try std.process.getEnvMap(alloc);

        try env_map.put(
            "FZF_DEFAULT_COMMAND",
            try state.concatPaths("rga --files-with-matches ''"),
        );

        proc.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        proc.stdout_behavior = std.ChildProcess.StdIo.Pipe;
        proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;
        proc.env_map = &env_map;
        proc.cwd = state.cwd;

        try proc.spawn();

        const res = try proc.stdout.?.readToEndAlloc(
            alloc,
            1024,
        );

        const term = try proc.wait();
        if (term != .Exited) return FindError.SubProcError;
        return res;
    }

    fn subprocFzfRga(state: *Finder) ![]const u8 {
        const cmd = FZF_INVOKE_COMMAND ++ [_][]const u8{
            "--preview",
            "[[ ! -z {} ]] && rga --pretty --context 5 {q} {}",

            "--bind",
            try state.concatPaths("change:reload:rga --files-with-matches {q}"),

            // make fzf emit the search term and the result
            "--bind",
            "enter:become(echo {q} {})",
        };

        const res = try state.spawnFzfProc(&cmd);
        return std.mem.trim(u8, res, " \t\n\r");
    }

    fn subprocRga(
        state: *Finder,
        search_term: []const u8,
        path: []const u8,
    ) ![]const u8 {
        var proc = std.ChildProcess.init(
            &.{
                "rga",
                "--line-number",
                search_term,
                path,
            },
            state.mem.child_allocator,
        );

        const alloc = state.mem.allocator();

        var env_map = try std.process.getEnvMap(alloc);

        proc.stdin_behavior = std.ChildProcess.StdIo.Pipe;
        proc.stdout_behavior = std.ChildProcess.StdIo.Pipe;
        proc.stderr_behavior = std.ChildProcess.StdIo.Pipe;
        proc.env_map = &env_map;
        proc.cwd = state.cwd;

        try proc.spawn();

        const res = try proc.stdout.?.readToEndAlloc(alloc, 1024);

        const term = try proc.wait();
        if (term != .Exited) return FindError.SubProcError;

        return std.mem.trim(u8, res, " \t\n\r");
    }

    const Result = struct {
        path: []const u8,
        search_term: []const u8,
        line_number: usize,
    };

    pub fn find(state: *Finder) !?Result {
        const selected = try state.subprocFzfRga();
        if (selected.len == 0) return null;

        const maybe_sep = std.mem.lastIndexOfScalar(u8, selected, ' ');

        if (maybe_sep) |sep| {
            const search_term = selected[0..sep];
            const path = selected[sep + 1 ..];

            // todo: this could instead use the json output of rg
            const grep_result = try state.subprocRga(search_term, path);

            const line_num_sep = std.mem.indexOfScalar(u8, grep_result, ':') orelse
                return null;

            return .{
                .path = path,
                .search_term = search_term,
                .line_number = try std.fmt.parseInt(
                    usize,
                    grep_result[0..line_num_sep],
                    10,
                ),
            };
        } else {
            return .{
                .path = selected,
                .search_term = "",
                .line_number = 0,
            };
        }
    }
};
