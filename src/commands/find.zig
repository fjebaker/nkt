const std = @import("std");
const cli = @import("../cli.zig");

const State = @import("../State.zig");
const Self = @This();

pub const alias = [_][]const u8{"f"};

pub const help = "Find in notes.";

const FindState = struct {
    paths: []const []const u8,
    mem: std.heap.ArenaAllocator,
    cwd: []const u8,

    pub fn init(
        alloc: std.mem.Allocator,
        cwd: []const u8,
        paths: []const []const u8,
    ) FindState {
        return .{
            .mem = std.heap.ArenaAllocator.init(alloc),
            .cwd = cwd,
            .paths = paths,
        };
    }

    pub fn deinit(self: *FindState) void {
        self.mem.deinit();
        self.* = undefined;
    }

    fn concatPaths(self: *FindState, root: []const u8) ![]const u8 {
        var alloc = self.mem.child_allocator;

        var paths = std.ArrayList([]const u8).fromOwnedSlice(
            alloc,
            try alloc.dupe([]const u8, self.paths),
        );
        defer paths.deinit();

        try paths.insert(0, root);

        return try std.mem.join(
            self.mem.allocator(),
            " ",
            paths.items,
        );
    }

    fn subprocFzfRga(self: *FindState) ![]const u8 {
        var proc = std.ChildProcess.init(
            &.{
                "fzf",
                "--sort",
                "--phony",

                "--preview",
                "[[ ! -z {} ]] && rga --pretty --context 5 {q} {}",

                "--preview-window",
                "70%:wrap",

                "--min-height",
                "20",

                "--height",
                "40%",

                "--bind",
                try self.concatPaths("change:reload:rga --files-with-matches {q}"),
            },
            self.mem.child_allocator,
        );

        var alloc = self.mem.allocator();

        var env_map = try std.process.getEnvMap(alloc);

        try env_map.put(
            "FZF_DEFAULT_COMMAND",
            try self.concatPaths("rga --files-with-matches ''"),
        );

        proc.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        proc.stdout_behavior = std.ChildProcess.StdIo.Pipe;
        proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;
        proc.env_map = &env_map;
        proc.cwd = self.cwd;

        try proc.spawn();

        var selected = try proc.stdout.?.readToEndAlloc(
            self.mem.child_allocator,
            1024,
        );

        var term = try proc.wait();
        if (term != .Exited) return FindError.SubProcError;

        return selected;
    }
};

const FindError = error{SubProcError};

prefix: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{};

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) return cli.CLIErrors.UnknownFlag;
        if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
        self.prefix = arg.string;
    }

    return self;
}

fn addPaths(
    alloc: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    dir: *const State.Directory,
) !void {
    var notelist = try dir.getChildList(alloc);
    defer notelist.deinit();

    for (notelist.items) |child| {
        try paths.append(child.info.path);
    }
}

fn directoryNotesUnder(
    alloc: std.mem.Allocator,
    root: []const u8,
    dir: *const State.Directory,
) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(alloc);
    try addPaths(alloc, &paths, dir);

    var notelist = try dir.getChildList(alloc);
    defer notelist.deinit();

    for (notelist.items) |child| {
        const name = child.info.name;
        if (std.mem.startsWith(u8, name, root)) {
            try paths.append(child.info.path);
        }
    }
    return paths.toOwnedSlice();
}

fn getAllPaths(alloc: std.mem.Allocator, state: *State) ![][]const u8 {
    var cnames = try state.getCollectionNames(alloc);
    defer cnames.deinit();

    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    for (cnames.items) |item| {
        switch (item.collection) {
            .Directory => {
                try addPaths(alloc, &paths, state.getDirectory(item.name).?);
            },
            .DirectoryWithJournal => {
                try addPaths(alloc, &paths, state.getDirectory(item.name).?);
            },
            else => {},
        }
    }

    return paths.toOwnedSlice();
}

pub fn run(
    self: *Self,
    state: *State,
    _: anytype,
) !void {
    var paths: [][]const u8 = if (self.prefix) |p|
        try directoryNotesUnder(
            state.allocator,
            p,
            state.getDirectory("notes").?,
        )
    else
        try getAllPaths(state.allocator, state);

    defer state.allocator.free(paths);

    var fs = FindState.init(state.allocator, state.fs.root_path, paths);
    defer fs.deinit();

    var selected = try fs.subprocFzfRga();
    defer state.allocator.free(selected);
}
