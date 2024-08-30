const std = @import("std");

const termui = @import("termui");
const farbe = @import("farbe");
const clippy = @import("clippy");

const Key = termui.TermUI.Key;

/// Wrapper for returning errors with helpful messages printed to `stderr`
pub fn throwError(err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = @errorName(err);

    const f = farbe.Farbe.init().fgRgb(255, 0, 0).bold();

    try writeFmtd(writer, "Error {s}: ", .{err_string}, f, stderr.isTty());

    try writer.print(fmt ++ "\n", args);

    // let the OS clean up
    std.process.exit(1);
    return err;
}

/// Write coloured output to the writer, but only if do_color is set.
/// Convenience method.
pub fn writeFmtd(
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
    f: farbe.Farbe,
    do_color: bool,
) !void {
    if (do_color) {
        try f.write(writer, fmt, args);
    } else {
        try writer.print(fmt, args);
    }
}

const Clippy = clippy.ClippyInterface(
    .{ .report_error_fn = throwError },
);

pub const CLIErrors = clippy.Error;
pub const ArgumentDescriptor = clippy.ArgumentDescriptor;
pub const ArgIterator = Clippy.ArgIterator;
pub const Arguments = Clippy.Arguments;
pub const Commands = Clippy.Commands;

pub const comptimeWrap = clippy.comptimeWrap;

pub fn RowIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const RowInfo = struct {
            item: T,
            row: usize,
            selected: bool,
        };

        display: *SearchDisplay,
        items: []const T,
        cfg: ResultDisplayConfig,
        row: usize = 0,

        fn init(display: *SearchDisplay, items: []const T) Self {
            return .{
                .display = display,
                .items = items,
                .cfg = display.resultConfiguration(items.len),
            };
        }

        /// Get the next row
        pub fn nextNoSkip(self: *Self) !?union(enum) { row: RowInfo, empty: usize } {
            if (self.row >= self.display.max_rows) return null;
            try self.display.moveAndClear(self.row);

            if (self.row < self.cfg.first_row) {
                self.row += 1;
                return .{ .empty = self.row };
            }

            const row_info: RowInfo = .{
                .item = self.items[
                    self.row + self.cfg.start - self.cfg.first_row
                ],
                .row = self.row,
                .selected = self.row == self.cfg.row,
            };
            self.row += 1;
            return .{ .row = row_info };
        }

        /// Get the next row
        pub fn next(self: *Self) !?RowInfo {
            var item = (try self.nextNoSkip()) orelse
                return null;
            while (item == .empty) {
                item = (try self.nextNoSkip()) orelse
                    return null;
            }
            return item.row;
        }
    };
}

pub const ResultDisplayConfig = struct {
    /// The index into the array which represents the current selected
    index: usize,
    /// The offset to find items when drawing results into rows
    start: usize,
    /// The row which has the currently selected
    row: usize,
    /// The index of the first row from the top (used to workout where to
    /// start drawing from)
    first_row: usize,
};

pub const SearchDisplay = struct {
    display: termui.TermUI.RowDisplay,
    text: [128]u8 = undefined,
    text_index: usize = 0,
    selected_index: usize = 0,
    max_selection: usize = 0,
    max_rows: usize = 10,
    scroll_offset: usize = 0,

    pub fn init(rows: usize) !SearchDisplay {
        var tui = try termui.TermUI.init(
            std.io.getStdIn(),
            std.io.getStdOut(),
        );
        tui.out.original.lflag.ISIG = true;
        tui.in.original.lflag.ISIG = true;
        tui.in.original.iflag.ICRNL = true;
        errdefer tui.deinit();
        return .{
            .display = try tui.rowDisplay(rows),
        };
    }

    pub fn deinit(self: *SearchDisplay) void {
        self.display.ctrl.tui.deinit();
        self.* = undefined;
    }

    /// Clear the display
    pub fn clear(self: *SearchDisplay, flush: bool) !void {
        try self.display.clear(flush);
    }

    /// Utility method to cleanup the screen
    pub fn cleanup(self: *SearchDisplay) !void {
        try self.clear(false);
        try self.display.moveToRow(0);
        try self.display.draw();
    }

    /// Draw the display
    pub fn draw(self: *SearchDisplay) !void {
        try self.display.moveToEnd();
        try self.display.ctrl.cursorToColumn(0);
        try self.display.ctrl.writer().print(
            " > {s}",
            .{self.getText()},
        );
        try self.display.draw();
    }

    /// Move the cursor to a row without clearing
    pub fn moveTo(self: *SearchDisplay, row: usize) !void {
        try self.display.moveToRow(row);
    }

    /// Move the cursor to a specific row and clear it
    pub fn moveAndClear(self: *SearchDisplay, row: usize) !void {
        try self.display.moveToRow(row);
        try self.display.ctrl.clearCurrentLine();
    }

    /// Get the text that has currently been entered
    pub fn getText(self: *const SearchDisplay) []const u8 {
        return self.text[0..self.text_index];
    }

    /// Set the text in the user buffer
    pub fn setText(self: *SearchDisplay, text: []const u8) void {
        @memcpy(self.text[0..text.len], text);
        self.text_index = text.len;
    }

    /// Get information about how to print the results
    pub fn resultConfiguration(
        self: *SearchDisplay,
        results_len: usize,
    ) ResultDisplayConfig {
        const start = results_len -| (self.max_rows + self.scroll_offset);
        const slice_len = results_len -| start;
        std.debug.assert(slice_len > 0);

        const first_row = self.max_rows -| slice_len;

        self.setMaxSelection(slice_len - 1);

        // offset which row we are pointing at
        const index = slice_len - self.selected_index - 1;
        const selected_row = index + first_row;

        return .{
            .index = index + start,
            .start = start,
            .first_row = first_row,
            .row = selected_row,
        };
    }

    /// Get an iterator for drawing rows easily
    pub fn rowIterator(
        self: *SearchDisplay,
        comptime T: type,
        items: []const T,
    ) RowIterator(T) {
        return RowIterator(T).init(self, items);
    }

    /// Get the index of the currently selected item from an array with `len`
    pub fn getSelected(
        self: *const SearchDisplay,
        len: usize,
    ) usize {
        const start = len -| self.max_rows;
        const remaining = len - start;
        return start + remaining - self.selected_index - 1;
    }

    /// Set the cursor to the maximum selectable
    pub fn setMaxSelection(self: *SearchDisplay, max: usize) void {
        self.max_selection = max;
        self.selected_index = @min(max, self.selected_index);
    }

    pub const Event = union(enum) {
        Cursor,
        Key,
        Enter,
        Tab,
        Ctrl: u8,
    };

    fn selectDown(self: *SearchDisplay) Event {
        if (self.selected_index <= self.scroll_offset) {
            self.scroll_offset -|= 1;
            self.selected_index = self.scroll_offset;
            return .Cursor;
        }
        self.selected_index -|= 1;
        return .Cursor;
    }

    fn selectUp(self: *SearchDisplay) Event {
        if (self.selected_index == self.max_selection) {
            self.scroll_offset += 1;
            self.selected_index += 1;
            return .Cursor;
        }

        self.selected_index = @min(
            self.selected_index + 1,
            self.max_selection,
        );
        return .Cursor;
    }

    fn pageUp(self: *SearchDisplay) Event {
        for (0..10) |_| {
            _ = self.selectUp();
        }
        return .Cursor;
    }

    fn pageDown(self: *SearchDisplay) Event {
        for (0..10) |_| {
            _ = self.selectDown();
        }
        return .Cursor;
    }

    /// Updates the display. Listens for key presses and acts accordingly,
    /// returning unhandled keys to the caller. Should be called as part of the
    /// main display loop.
    pub fn update(self: *SearchDisplay) !?Event {
        while (true) {
            const inp = try self.display.ctrl.tui.nextInput();
            switch (inp) {
                .char => |c| switch (c) {
                    Key.CtrlC => return null,
                    Key.CtrlD => return self.pageDown(),
                    Key.CtrlU => return self.pageUp(),
                    Key.CtrlJ => return self.selectDown(),
                    Key.CtrlK => return self.selectUp(),
                    // CtrlW
                    23 => {
                        const index = std.mem.lastIndexOfScalar(
                            u8,
                            std.mem.trimRight(u8, self.getText(), " "),
                            ' ',
                        ) orelse 0;
                        self.text_index = index;
                        break;
                    },
                    // CtrlN
                    14 => return .{ .Ctrl = 'n' },
                    Key.Enter => return .Enter,
                    Key.Tab => return .Tab,
                    Key.Backspace => {
                        if (self.text_index > 0) {
                            self.text_index -|= 1;
                            break;
                        }
                    },
                    else => {
                        self.text[self.text_index] = c;
                        self.text_index = @min(
                            self.text_index + 1,
                            self.text.len - 1,
                        );
                        break;
                    },
                },
                .Up => return self.selectUp(),
                .Down => return self.selectDown(),
                else => {},
            }
        }
        return .Key;
    }
};
