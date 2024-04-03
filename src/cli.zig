const std = @import("std");

const farbe = @import("farbe");
const clippy = @import("clippy");

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
