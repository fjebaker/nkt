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

pub const TextAndDisplay = struct {
    display: termui.TermUI.RowDisplay,
    text: [128]u8 = undefined,
    text_index: usize = 0,
    selected: bool = false,

    pub fn init(rows: usize) !TextAndDisplay {
        var tui = try termui.TermUI.init(
            std.io.getStdIn(),
            std.io.getStdOut(),
        );
        // tui.out.original.lflag.ISIG = true;
        // tui.in.original.lflag.ISIG = true;
        errdefer tui.deinit();
        return .{
            .display = try tui.rowDisplay(rows),
        };
    }

    pub fn deinit(self: *TextAndDisplay) void {
        self.display.ctrl.tui.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *TextAndDisplay, flush: bool) !void {
        try self.display.clear(flush);
    }

    pub fn draw(self: *TextAndDisplay) !void {
        try self.display.moveToEnd();
        try self.display.ctrl.cursorToColumn(0);
        try self.display.ctrl.writer().print(
            " > {s}",
            .{self.getTextSlice()},
        );
        try self.display.draw();
    }

    pub fn moveTo(self: *TextAndDisplay, row: usize) !void {
        try self.display.moveToRow(row);
    }

    fn getTextSlice(self: *const TextAndDisplay) []const u8 {
        return self.text[0..self.text_index];
    }

    pub fn moveAndClear(self: *TextAndDisplay, row: usize) !void {
        try self.display.moveToRow(row);
        try self.display.ctrl.clearCurrentLine();
    }

    pub fn getText(self: *TextAndDisplay) !?[]const u8 {
        while (true) {
            const inp = try self.display.ctrl.tui.nextInput();
            switch (inp) {
                .char => |c| switch (c) {
                    Key.CtrlC, Key.CtrlD => return null,
                    Key.Enter => {
                        self.selected = true;
                        return null;
                    },
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
        return self.getTextSlice();
    }
};
