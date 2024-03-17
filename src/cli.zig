const std = @import("std");

const farbe = @import("farbe");
const clippy = @import("clippy");

/// Wrapper for returning errors with helpful messages printed to `stderr`
pub fn throwError(err: anyerror, comptime fmt: []const u8, args: anytype) !void {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = @errorName(err);

    // do we use color?
    if (stderr.isTty()) {
        const f = farbe.ComptimeFarbe.init().fgRgb(255, 0, 0).bold();
        try f.write(writer, "{s}: ", .{err_string});
    } else {
        try writer.print("{s}: ", .{err_string});
    }
    try writer.print(fmt ++ "\n", args);

    // let the OS clean up
    std.process.exit(1);
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
