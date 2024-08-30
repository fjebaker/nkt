const std = @import("std");
const cli = @import("../cli.zig");
const color = @import("../colors.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const tracy = @import("../tracy.zig");

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
        .help = "Seach should be case sensitive",
    },
    .{
        .arg = "--rows n",
        .help = "Number of rows to show results in",
        .argtype = usize,
        .default = "20",
    },
    .{
        .arg = "--preview width",
        .help = "Preview width as a percentage of the total terminal",
        .argtype = usize,
        .default = "60",
    },
});

what: ?[]const u8,
case_sensitive: bool,
rows: usize,
preview_size: usize,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    const rows = args.rows;
    if (rows < 3) {
        return cli.throwError(cli.CLIErrors.BadArgument, "Rows must be at least 4", .{});
    }
    return .{
        .what = args.what,
        .case_sensitive = args.case,
        .rows = rows,
        .preview_size = args.preview,
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
        return cli.throwError(
            Root.Error.NoSuchCollection,
            "No such directory '{s}'",
            .{dirname},
        );
    };

    const note_descriptors: []Directory.Note = if (self.what) |p|
        try directoryNotesUnder(
            allocator,
            p,
            dir,
        )
    else
        try getAllInfos(allocator, root);
    defer allocator.free(note_descriptors);

    var heap = std.heap.ArenaAllocator.init(allocator);
    defer heap.deinit();

    const tmp_alloc = heap.allocator();

    var contents = std.ArrayList([]const u8).init(allocator);
    defer contents.deinit();

    var chunk_machine = searching.ChunkMachine.init(allocator);
    defer chunk_machine.deinit();

    // read all note contents, and split with the chunk machine into small
    // chunks to be searched in
    for (note_descriptors) |info| {
        const content = try root.fs.?.readFileAlloc(tmp_alloc, info.path);
        try chunk_machine.add(content);
    }

    // run the search loop to get the users chocie
    const choice = try self.doSearchLoop(allocator, note_descriptors, &chunk_machine);

    if (choice) |c| {
        const info = note_descriptors[c.item.index];
        const path = info.path;
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

const Result = searching.ChunkMachine.Result;
const ResultList = searching.ChunkMachine.ResultList;

/// Run the interactive search loop that allows the user to search and have the
/// results displayed interactively.
pub fn doSearchLoop(
    self: *Self,
    allocator: std.mem.Allocator,
    note_descriptors: []const Directory.Note,
    chunk_machine: *searching.ChunkMachine,
) !?Result {
    var searcher = try chunk_machine.searcher(
        allocator,
        .{
            .case_sensitive = self.case_sensitive,
            .case_penalize = true,
        },
    );
    defer searcher.deinit();

    var display = try cli.SearchDisplay.init(self.rows);
    defer display.deinit();

    try display.clear(false);
    try display.draw();

    const max_rows = display.display.max_rows - 2;
    display.max_rows = max_rows;

    const display_writer = display.display.ctrl.writer();

    var needle: []const u8 = "";
    var results: ?ResultList = null;
    var runtime: u64 = 0;
    var choice: ?Result = null;

    tracy.frameMarkNamed("setup_completed");

    while (try display.update()) |event| {
        var t_ctx = tracy.trace(@src());
        defer t_ctx.end();

        const term_size = try display.display.ctrl.tui.getSize();
        const preview_columns = @divFloor(
            (term_size.col * self.preview_size),
            100,
        );

        try display.clear(false);

        switch (event) {
            .Key => {
                needle = display.getText();
                if (needle.len > 0) {
                    var timer = try std.time.Timer.start();
                    results = try searcher.search(needle);

                    if (results) |rs| {
                        // sort by last modified
                        std.sort.heap(
                            Result,
                            rs.results,
                            note_descriptors,
                            sortLastModified,
                        );
                    }

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

        if (results != null and results.?.results.len > 0) {
            const rs = results.?;

            // make sure the cursor is not past the end of the number of
            // results
            if (display.selected_index >= rs.results.len) {
                display.selected_index = rs.results.len - 1;
            }

            const rd = display.resultConfiguration(rs.results.len);

            const s_result = rs.results[rd.index];
            const selected_item = s_result.item.*;

            const best_match =
                chunk_machine.getValueFromChunk(
                selected_item,
            );

            var preview = searching.previewDisplay(
                best_match,
                selected_item.line_no,
                s_result.matches,
                s_result.item.start,
                preview_columns - PREVIEW_SIZE_PADDING - 14,
            );

            var tmp_row_itt = display.rowIterator(
                Result,
                rs.results,
            );

            const max_len = term_size.col -
                preview_columns -
                PREVIEW_SIZE_PADDING;

            while (try tmp_row_itt.nextNoSkip()) |maybe_row| {
                switch (maybe_row) {
                    .row => |ri| {
                        if (ri.selected) {
                            try color.GREEN.bold().write(display_writer, " >> ", .{});
                        } else {
                            try display_writer.writeAll("    ");
                        }
                        const score: usize = if (ri.item.score) |s| @intCast(@abs(s)) else 0;
                        try color.DIM.write(
                            display_writer,
                            "[{d: >4}] ",
                            .{score},
                        );
                        const written = try ri.item.printMatched(
                            display_writer,
                            14,
                            max_len,
                        );

                        try display_writer.writeByteNTimes(
                            ' ',
                            PREVIEW_SIZE_PADDING - 1 + max_len - written,
                        );
                    },
                    .empty => {
                        try display_writer.writeByteNTimes(
                            ' ',
                            PREVIEW_SIZE_PADDING - 1 + max_len + 11,
                        );
                    },
                }

                const i = switch (maybe_row) {
                    .row => maybe_row.row.row,
                    .empty => maybe_row.empty,
                };

                // preview
                try display_writer.writeByte('|');
                try display_writer.writeByteNTimes(' ', 1);

                if (i == 0) {
                    const info = note_descriptors[selected_item.index];
                    try display_writer.print("File: {s} (modified: {s})", .{
                        info.path,
                        try info.modified.formatDateTime(),
                    });
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
    try display.cleanup();

    return choice;
}

fn sortLastModified(
    note_descriptors: []const Directory.Note,
    lhs: Result,
    rhs: Result,
) bool {
    if (lhs.scoreEqual(rhs)) {
        const lhs_info = note_descriptors[lhs.item.index];
        const rhs_info = note_descriptors[rhs.item.index];
        return Directory.Note.sortModified({}, lhs_info, rhs_info);
    }
    return lhs.scoreLessThan(rhs);
}

fn directoryNotesUnder(
    alloc: std.mem.Allocator,
    root: []const u8,
    dir: Directory,
) ![]Directory.Note {
    var note_descriptors = std.ArrayList(Directory.Note).init(alloc);
    for (dir.info.notes) |note| {
        if (std.mem.startsWith(u8, note.name, root)) {
            try note_descriptors.append(note);
        }
    }
    return note_descriptors.toOwnedSlice();
}

fn getAllInfos(alloc: std.mem.Allocator, root: *Root) ![]Directory.Note {
    var note_descriptors = std.ArrayList(Directory.Note).init(alloc);
    errdefer note_descriptors.deinit();

    for (root.info.directories) |d| {
        const dir = (try root.getDirectory(d.name)).?;
        for (dir.info.notes) |note| {
            try note_descriptors.append(note);
        }
    }

    return try note_descriptors.toOwnedSlice();
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
