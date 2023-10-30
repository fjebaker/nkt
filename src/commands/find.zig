const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Self = @This();
const Printer = @import("../Printer.zig");

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

                // make fzf emit the search term and the result
                "--bind",
                "enter:become(echo {q} {})",
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
    dir: *State.Collection,
) !void {
    var notelist = try dir.getAll(alloc);
    defer alloc.free(notelist);

    for (notelist) |note| {
        try paths.append(note.getPath());
    }
}

fn directoryNotesUnder(
    alloc: std.mem.Allocator,
    root: []const u8,
    dir: *State.Collection,
) ![][]const u8 {
    if (dir.* != .Directory) unreachable;

    var paths = std.ArrayList([]const u8).init(alloc);

    var notelist = try dir.getAll(alloc);
    defer alloc.free(notelist);

    for (notelist) |note| {
        const name = note.getName();
        if (std.mem.startsWith(u8, name, root)) {
            try paths.append(note.getPath());
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
            else => {},
        }
    }

    return paths.toOwnedSlice();
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
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

    const out = std.mem.trim(u8, selected, " \t\n\r");

    const sep = std.mem.indexOfScalar(u8, out, ' ') orelse return;
    const search_term = out[0..sep];
    _ = search_term;
    const path = out[sep + 1 ..];

    try readFile(state, path, out_writer);
}

fn readFile(state: *State, path: []const u8, out_writer: anytype) !void {
    var printer = Printer.init(state.allocator, null);
    defer printer.deinit();

    if (path.len == 0) return;
    const c_name = utils.inferCollectionName(path).?;
    var collection = state.getCollectionByName(c_name).?;

    var note = collection.directory.?.getByPath(path).?;

    const content = try note.Note.read();
    try printer.addHeading("", .{});
    _ = try printer.addLine("{s}", .{content});

    try printer.drain(out_writer);
}
