const std = @import("std");
const fuzzig = @import("fuzzig");
const searching = @import("searching.zig");
const cli = @import("cli.zig");
const color = @import("colors.zig");

const Searcher = searching.Searcher;

/// A utility structure to help search through a list of strings (e.g. names of
/// items)
pub const StringSearch = struct {
    const Key = struct { index: usize };
    pub const Search = Searcher(Key);

    allocator: std.mem.Allocator,
    strings: []const []const u8,
    keys: []Key,
    searcher: Search,

    pub fn init(
        allocator: std.mem.Allocator,
        strings: []const []const u8,
        opts: fuzzig.AsciiOptions,
    ) !StringSearch {
        // allocate a key for each item
        const keys = try allocator.alloc(Key, strings.len);
        errdefer allocator.free(keys);

        // assign monotonic indices
        for (keys, 0..) |*k, i| {
            k.* = .{ .index = i };
        }

        var searcher = try Search.initItems(
            allocator,
            keys,
            strings,
            opts,
        );
        errdefer searcher.deinit();

        return .{
            .allocator = allocator,
            .strings = strings,
            .keys = keys,
            .searcher = searcher,
        };
    }

    pub fn deinit(self: *StringSearch) void {
        self.searcher.deinit();
        self.allocator.free(self.keys);
        self.* = undefined;
    }

    pub fn search(self: *StringSearch, needle: []const u8) !Search.ResultList {
        return try self.searcher.search(needle);
    }

    pub fn CallbackTable(comptime Ctx: type, comptime T: type) type {
        return struct {
            /// Used to handle control characters. Should return true to
            /// interrupt the search.
            handleControl: fn (Ctx, char: u8, []const u8) anyerror!bool,
            /// Used to draw items to the screen in the correct way with the
            /// right meta data.
            drawItem: fn (Ctx, anytype, T, color.Farbe) anyerror!void,
            /// Used to sort the results
            sortResults: fn (Ctx, []Search.Result, []const T) void,
        };
    }

    fn drawDefault(
        _: *const StringSearch,
        ctx: anytype,
        comptime T: type,
        items: []const T,
        comptime table: CallbackTable(@TypeOf(ctx), T),
        display: *cli.SearchDisplay,
    ) !void {
        const display_writer = display.display.ctrl.writer();
        var row_itt = display.rowIterator(T, items);
        while (try row_itt.next()) |ri| {
            if (ri.selected) {
                try color.GREEN.bold().write(display_writer, " >> ", .{});
            } else {
                try display_writer.writeAll("    ");
            }
            try color.DIM.write(
                display_writer,
                "[{d: >4}] ",
                .{0},
            );
            try table.drawItem(ctx, display_writer, ri.item, color.DIM);
        }
        try display.draw();
    }

    /// Run the search interactively, rendering a small TUI to the user and
    /// allowing them to fuzzily search through the string
    ///
    /// Caller must pass a function which is used to render the item on each
    /// row.
    ///
    /// Returns the index of the chosen item, or null if no item was chosen.
    pub fn interactiveDisplay(
        self: *StringSearch,
        ctx: anytype,
        comptime T: type,
        items: []const T,
        comptime table: CallbackTable(@TypeOf(ctx), T),
    ) !?usize {
        std.debug.assert(items.len == self.strings.len);

        // first we setup the display
        var display = try cli.SearchDisplay.init(18);
        defer display.deinit();

        const max_rows = display.display.max_rows - 1;
        display.max_rows = max_rows;

        const display_writer = display.display.ctrl.writer();

        try display.clear(false);

        // and draw all of the strings dimmed out
        try self.drawDefault(ctx, T, items, table, &display);

        // now we start the interactive search loop
        var needle: []const u8 = "";
        var results: ?Search.ResultList = null;
        var choice: ?usize = null;

        while (try display.update()) |event| {
            const term_size = try display.display.ctrl.tui.getSize();
            try display.clear(false);
            switch (event) {
                .Tab, .Key => {
                    needle = display.getText();
                    if (needle.len > 0) {
                        // tab complete up to the next `.`
                        if (event == .Tab and results != null) {
                            const rs = results.?.results;
                            const ci = rs[display.getSelected(rs.len)].string;
                            const j =
                                std.mem.indexOfScalarPos(u8, ci, needle.len, '.') orelse
                                ci.len;

                            display.setText(ci[0..j]);
                            needle = display.getText();
                        }
                        results = try self.search(needle);
                        if (results.?.results.len == 0) {
                            results = null;
                        }

                        if (results != null) {
                            // allow optional sorting
                            table.sortResults(ctx, results.?.results, items);
                        }
                    } else {
                        results = null;
                    }
                },
                .Ctrl => |key| {
                    if (try table.handleControl(ctx, key, needle)) {
                        break;
                    }
                },
                .Enter => {
                    if (results) |rs| {
                        choice = rs.results[
                            display.getSelected(rs.results.len)
                        ].item.index;
                        break;
                    } else if (display.getText().len == 0) {
                        choice = display.getSelected(self.strings.len);
                        break;
                    }
                },
                else => {},
            }

            if (results != null and results.?.results.len > 0) {
                var tmp_row_itt = display.rowIterator(
                    Search.Result,
                    results.?.results,
                );
                while (try tmp_row_itt.next()) |ri| {
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
                    _ = try ri.item.printMatched(
                        display_writer,
                        14,
                        term_size.col,
                    );
                }
            } else if (display.getText().len == 0) {
                try self.drawDefault(ctx, T, items, table, &display);
            }

            try display.draw();
        }

        // cleanup
        try display.cleanup();
        return choice;
    }
};
