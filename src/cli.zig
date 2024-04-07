const std = @import("std");

const termui = @import("termui");
const farbe = @import("farbe");
const clippy = @import("clippy");

const Key = termui.TermUI.Key;

/// Wrapper for returning errors with helpful messages printed to `stderr`
pub fn throwError(err: anyerror, comptime fmt: []const u8, args: anytype) !void {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = @errorName(err);

    const f = farbe.ComptimeFarbe.init().fgRgb(255, 0, 0).bold();

    try writeFmtd(writer, "Error {s}: ", .{err_string}, f.fixed(), stderr.isTty());

    try writer.print(fmt ++ "\n", args);

    // let the OS clean up
    std.process.exit(1);
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

pub const SearchDisplay = struct {
    display: termui.TermUI.RowDisplay,
    text: [128]u8 = undefined,
    text_index: usize = 0,
    selected_index: usize = 0,
    max_selection: usize = 0,

    pub fn init(rows: usize) !SearchDisplay {
        var tui = try termui.TermUI.init(
            std.io.getStdIn(),
            std.io.getStdOut(),
        );
        tui.out.original.lflag.ISIG = true;
        tui.in.original.lflag.ISIG = true;
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

    pub fn setMaxSelection(self: *SearchDisplay, max: usize) void {
        self.max_selection = max;
        self.selected_index = @min(max, self.selected_index);
    }

    pub const Event = union(enum) {
        Cursor,
        Key,
        Enter,
    };

    pub fn update(self: *SearchDisplay) !?Event {
        while (true) {
            const inp = try self.display.ctrl.tui.nextInput();
            switch (inp) {
                .char => |c| switch (c) {
                    Key.CtrlC, Key.CtrlD => return null,
                    Key.CtrlJ => {
                        self.selected_index -|= 1;
                        return .Cursor;
                    },
                    Key.CtrlK => {
                        self.selected_index = @min(
                            self.selected_index + 1,
                            self.max_selection,
                        );
                        return .Cursor;
                    },
                    Key.Enter => return .Enter,
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
                else => {},
            }
        }
        return .Key;
    }
};
