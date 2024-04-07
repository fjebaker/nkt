const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

// const Finder = @import("../search.zig").Finder;
const Searcher = @import("../searching.zig").Searcher;
const Editor = @import("../Editor.zig");
const BlockPrinter = @import("../BlockPrinter.zig");

const Self = @This();

pub const alias = [_][]const u8{ "f", "fp", "fe", "fr", "fo" };

pub const short_help = "Find in notes.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{.{
    .arg = "what",
    .help = "What to search in",
}});

what: ?[]const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    return .{
        .what = args.what,
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try root.load();

    const dirname = root.info.default_directory;

    const dir = (try root.getDirectory(dirname)) orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No such directory '{s}'",
            .{dirname},
        );
        unreachable;
    };

    const paths: [][]const u8 = if (self.what) |p|
        try directoryNotesUnder(
            allocator,
            p,
            dir,
        )
    else
        try getAllPaths(allocator, root);
    defer allocator.free(paths);

    var heap = std.heap.ArenaAllocator.init(allocator);
    defer heap.deinit();

    const tmp_alloc = heap.allocator();

    var items = std.ArrayList([]const u8).init(allocator);
    defer items.deinit();

    var contents = std.ArrayList([]const u8).init(allocator);
    defer contents.deinit();

    // read all note contents into buffers, split into individual lines
    for (paths) |p| {
        const content = try root.fs.?.readFileAlloc(tmp_alloc, p);
        var line_itt = std.mem.tokenizeAny(u8, content, "\n");
        while (line_itt.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            // skip excessively short lines
            if (trimmed.len <= 3) continue;
            try items.append(p);
            try contents.append(trimmed);
        }
    }

    var searcher = try Searcher([]const u8).initItems(
        allocator,
        items.items,
        contents.items,
        .{},
    );
    defer searcher.deinit();

    var display = try cli.TextAndDisplay.init(20);
    defer display.deinit();

    try display.clear(false);
    try display.draw();

    const display_writer = display.display.ctrl.writer();
    while (try display.getText()) |needle| {
        try display.clear(false);
        if (needle.len > 0) {
            var timer = try std.time.Timer.start();
            const results = try searcher.search(needle);
            const runtime = timer.lap();

            const max_rows = display.display.max_rows - 2;

            const start = results.results.len -| max_rows;
            const slice = results.results[start..];

            const first_row = max_rows -| slice.len;

            for (first_row.., slice) |row, res| {
                try display.moveAndClear(row);
                if (res.score) |scr| {
                    try display_writer.print("[{d: >4}] ", .{scr});
                    try res.printMatched(display_writer, 14, 70);
                }
            }

            try display.display.printToRowC(
                max_rows,
                "---- {s} ({d} / {d}) = {d} ---",
                .{
                    std.fmt.fmtDuration(results.runtime),
                    results.results.len,
                    items.items.len,
                    std.fmt.fmtDuration(runtime),
                },
            );
        }

        try display.draw();
    }

    try writer.writeByte('\n');

    // var finder = Finder.init(allocator, root.fs.?.root_path, paths);
    // defer finder.deinit();

    // const selected = try finder.find() orelse return;

    // std.log.default.debug("Selected: {s}:{d}", .{ selected.path, selected.line_number });

    // try editFileAt(allocator, root, selected.path, selected.line_number, opts);
}

fn directoryNotesUnder(
    alloc: std.mem.Allocator,
    root: []const u8,
    dir: Directory,
) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(alloc);
    for (dir.info.notes) |note| {
        if (std.mem.startsWith(u8, note.name, root)) {
            try paths.append(note.path);
        }
    }
    return paths.toOwnedSlice();
}

fn getAllPaths(alloc: std.mem.Allocator, root: *Root) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    for (root.info.directories) |d| {
        const dir = (try root.getDirectory(d.name)).?;
        for (dir.info.notes) |note| {
            try paths.append(note.path);
        }
    }

    return try paths.toOwnedSlice();
}

fn editFileAt(
    allocator: std.mem.Allocator,
    root: *Root,
    path: []const u8,
    line: usize,
    _: commands.Options,
) !void {
    if (path.len == 0) return;
    const c_name = utils.inferCollectionName(path).?;
    var dir = (try root.getDirectory(c_name)).?;

    const note_name = std.fs.path.stem(path);

    var note = dir.getNotePtr(note_name).?;
    note.modified = time.Time.now();
    root.markModified(dir.descriptor, .CollectionDirectory);
    try root.writeChanges();

    const abs_path = try root.fs.?.absPathify(allocator, path);
    defer allocator.free(abs_path);

    // this only works for vim
    const line_selector = try std.fmt.allocPrint(
        allocator,
        "+{d}",
        .{line},
    );
    defer allocator.free(line_selector);

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.becomeWithArgs(abs_path, &.{line_selector});
}
