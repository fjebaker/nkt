const std = @import("std");
const cli = @import("../cli.zig");
const colors = @import("../colors.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const searching = @import("../searching.zig");
const Editor = @import("../Editor.zig");

const Self = @This();

const PREVIEW_SIZE_PADDING = 3; // num columns

pub const alias = [_][]const u8{ "f", "fp", "fe", "fr", "fo" };

pub const short_help = "Find in notes.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "what",
        .help = "What to search in",
    },
    .{
        .arg = "--case",
        .help = "Seach should be case sensitive (Default: false)",
    },
    .{
        .arg = "--rows n",
        .help = "Number of rows to show results in (Default: 20)",
        .argtype = usize,
    },
    .{
        .arg = "--preview width",
        .help = "Preview width as a percentage of the total terminal (Default: 60)",
        .argtype = usize,
    },
});

what: ?[]const u8,
case_sensitive: bool,
rows: usize,
preview_size: usize,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    const rows = args.rows orelse 20;
    if (rows < 3) {
        try cli.throwError(cli.CLIErrors.BadArgument, "Rows must be at least 4", .{});
        unreachable;
    }
    return .{
        .what = args.what,
        .case_sensitive = args.case,
        .rows = rows,
        .preview_size = args.preview orelse 60,
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
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

    var contents = std.ArrayList([]const u8).init(allocator);
    defer contents.deinit();

    var chunk_machine = searching.ChunkMachine.init(allocator);
    defer chunk_machine.deinit();

    // read all note contents into buffers
    for (paths) |p| {
        const content = try root.fs.?.readFileAlloc(tmp_alloc, p);
        try chunk_machine.add(p, content);
    }

    var searcher = try chunk_machine.searcher(
        allocator,
        .{ .case_sensitive = self.case_sensitive },
    );
    defer searcher.deinit();

    var display = try cli.SearchDisplay.init(self.rows);
    defer display.deinit();

    try display.clear(false);
    try display.draw();

    const max_rows = display.display.max_rows - 2;

    const display_writer = display.display.ctrl.writer();

    var needle: []const u8 = "";
    var results: ?searching.ChunkMachine.SearcherType.ResultList = null;
    var runtime: u64 = 0;
    var choice: ?searching.ChunkMachine.SearcherType.Result = null;
    while (try display.update()) |event| {
        const term_size = try display.display.ctrl.tui.getSize();
        const preview_columns = @divFloor(
            (term_size.ws_col * self.preview_size),
            100,
        );

        try display.clear(false);

        switch (event) {
            .Key => {
                needle = display.getText();
                if (needle.len > 0) {
                    var timer = try std.time.Timer.start();
                    results = try searcher.search(needle);
                    runtime = timer.lap();
                } else {
                    results = null;
                }
            },
            .Enter => {
                if (results) |rs| {
                    const start = rs.results.len -| max_rows;
                    const slice = rs.results[start..];
                    const index = slice.len - display.selected_index - 1;
                    choice = slice[index];
                    break;
                }
            },
            else => {},
        }

        if (results) |rs| {
            const start = rs.results.len -| max_rows;
            const slice = rs.results[start..];
            if (slice.len == 0) continue;

            const first_row = max_rows -| slice.len;

            display.setMaxSelection(slice.len - 1);

            // offset which row we are pointing at
            const index = slice.len - display.selected_index - 1;
            const selected_row = index + first_row;
            const selected_item = slice[index].item.*;

            const best_match =
                if (slice.len > 0)
                chunk_machine.getValueFromChunk(
                    selected_item,
                )
            else
                "";

            var preview = searching.previewDisplay(
                best_match,
                selected_item.line_no,
                slice[index].matches,
                slice[index].item.start,
                preview_columns - PREVIEW_SIZE_PADDING - 14,
            );

            for (0..max_rows) |i| {
                try display.moveAndClear(i);
                const max_len = term_size.ws_col -
                    preview_columns -
                    PREVIEW_SIZE_PADDING;

                if (i == selected_row) {
                    try colors.GREEN.bold().write(display_writer, " >> ", .{});
                } else {
                    try display_writer.writeAll("    ");
                }

                if (i >= first_row) {
                    const res = slice[i - first_row];
                    if (res.score) |scr| {
                        try display_writer.print(
                            "[{d: >4}] ",
                            .{@as(usize, @intCast(@abs(scr)))},
                        );

                        const written = try res.printMatched(
                            display_writer,
                            14,
                            max_len,
                        );

                        try display_writer.writeByteNTimes(
                            ' ',
                            PREVIEW_SIZE_PADDING - 1 + max_len - written,
                        );
                    }
                } else {
                    try display_writer.writeByteNTimes(
                        ' ',
                        PREVIEW_SIZE_PADDING - 1 + max_len + 7,
                    );
                }

                // preview
                try display_writer.writeByte('|');
                try display_writer.writeByteNTimes(' ', 1);

                if (i == 0) {
                    const path = chunk_machine.getKeyFromChunk(selected_item);
                    try display_writer.print("File: {s}", .{path});
                    //
                } else if (i > 1) {
                    try preview.writeNext(display_writer);
                }
            }
        }

        try display.display.printToRowC(
            max_rows,
            " (matched {d} / {d} :: search {d} total {d}) ",
            .{
                if (results) |rs| rs.results.len else chunk_machine.numItems(),
                chunk_machine.numItems(),
                std.fmt.fmtDuration(if (results) |rs| rs.runtime else 0),
                std.fmt.fmtDuration(runtime),
            },
        );
        try display.draw();
    }

    // cleanup
    try display.clear(false);
    try display.display.moveToRow(0);
    try display.display.draw();

    if (choice) |c| {
        const path = chunk_machine.getKeyFromChunk(c.item.*);
        const line_no = c.item.line_no;
        std.log.default.debug(
            "Selected: {s}:{d}",
            .{ path, line_no },
        );
        try editFileAt(allocator, root, path, line_no, opts);
    } else {
        try writer.writeAll("No item selected\n");
    }
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
