const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const Self = @This();
const BlockPrinter = @import("../BlockPrinter.zig");

const read_cmd = @import("read.zig");
const Editor = @import("../Editor.zig");

pub const alias = [_][]const u8{ "f", "fp", "fe", "fr" };

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

    pub fn deinit(state: *FindState) void {
        state.mem.deinit();
        state.* = undefined;
    }

    fn concatPaths(state: *FindState, root: []const u8) ![]const u8 {
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

    fn subprocFzfRga(state: *FindState) ![]const u8 {
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
                try state.concatPaths("change:reload:rga --files-with-matches {q}"),

                // make fzf emit the search term and the result
                "--bind",
                "enter:become(echo {q} {})",
            },
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

        return std.mem.trim(u8, res, " \t\n\r");
    }

    fn subprocRga(
        state: *FindState,
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

    pub fn find(state: *FindState) !?Result {
        const selected = try state.subprocFzfRga();

        const sep = std.mem.indexOfScalar(u8, selected, ' ') orelse
            return null;
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
    }
};

const FindError = error{SubProcError};

prefix: ?[]const u8 = null,
mode: ?enum { Read, Page, Edit } = null,
what: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    itt.rewind();
    const prog_name = (try itt.next()).?.string;
    if (prog_name.len == 2) switch (prog_name[1]) {
        'r' => self.mode = .Read,
        'p' => self.mode = .Page,
        'e' => self.mode = .Edit,
        else => return cli.CLIErrors.BadArgument,
    };

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('r', "read")) {
                if (self.mode != null) return cli.CLIErrors.DuplicateFlag;
                self.mode = .Read;
            } else if (arg.is('e', "edit")) {
                if (self.mode != null) return cli.CLIErrors.DuplicateFlag;
                self.mode = .Edit;
            } else if (arg.is('a', "all")) {
                if (self.what != null) return cli.CLIErrors.DuplicateFlag;
            } else if (arg.is('p', "page")) {
                if (self.mode != null) return cli.CLIErrors.DuplicateFlag;
                self.mode = .Page;
            } else return cli.CLIErrors.UnknownFlag;
        }
        if (arg.index.? > 1) return cli.CLIErrors.TooManyArguments;
        self.prefix = arg.string;
    }

    self.mode = self.mode orelse .Edit;
    self.what = self.what orelse "notes";

    return self;
}

fn addPaths(
    alloc: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    dir: *State.Collection,
) !void {
    const notelist = try dir.getAll(alloc);
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

    const notelist = try dir.getAll(alloc);
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
    const paths: [][]const u8 = if (self.prefix) |p|
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

    const selected = try fs.find() orelse return;

    switch (self.mode.?) {
        .Read => try readFile(state, selected.path, false, out_writer),
        .Page => try readFile(state, selected.path, true, out_writer),
        .Edit => try editFileAt(state, selected.path, selected.line_number),
    }
}

fn editFileAt(state: *State, path: []const u8, line: usize) !void {
    if (path.len == 0) return;
    const c_name = utils.inferCollectionName(path).?;
    var collection = state.getCollectionByName(c_name).?;

    var note = collection.directory.?.getByPath(path).?;
    note.Note.note.modified = utils.now();
    try state.writeChanges();

    const abs_path = try state.fs.absPathify(state.allocator, path);
    defer state.allocator.free(abs_path);

    // this only works for vim
    const line_selector = try std.fmt.allocPrint(state.allocator, "+{d}", .{line});
    defer state.allocator.free(line_selector);

    var editor = try Editor.init(state.allocator);
    defer editor.deinit();

    try editor.becomeWithArgs(abs_path, &.{line_selector});
}

fn readFile(state: *State, path: []const u8, page: bool, out_writer: anytype) !void {
    if (path.len == 0) return;
    const c_name = utils.inferCollectionName(path).?;
    var collection = state.getCollectionByName(c_name).?;

    const note = collection.directory.?.getByPath(path).?;

    var printer = BlockPrinter.init(state.allocator, .{ .pretty = false });
    defer printer.deinit();

    try read_cmd.readNote(note, &printer);

    if (page) {
        var buf = std.ArrayList(u8).init(state.allocator);
        defer buf.deinit();
        try printer.drain(buf.writer());
        try read_cmd.pipeToPager(state.allocator, state.topology.pager, buf.items);
    } else {
        try printer.drain(out_writer);
    }
}
