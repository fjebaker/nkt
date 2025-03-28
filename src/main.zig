/// This is a docs test to see if it comes up.
const std = @import("std");
const cli = @import("cli.zig");
const selections = @import("selections.zig");
const utils = @import("utils.zig");
const processing = @import("processing.zig");
const searching = @import("searching.zig");

const Root = @import("topology/Root.zig");
const time = @import("topology/time.zig");
const FileSystem = @import("FileSystem.zig");
const commands = @import("commands.zig");

const color = @import("colors.zig");

const help = @import("commands/help.zig");

pub const clippy_options: @import("clippy").Options = .{
    .errorFn = cli.throwError,
};

test "main" {
    _ = Root;
    _ = cli;
    _ = selections;
    _ = commands;
    _ = time;
    _ = processing;
    _ = searching;
    _ = @import("test/main.zig");
}

// configure logging
pub const std_options: std.Options = .{
    // Define logFn to override the std implementation
    .logFn = loggerFn,
};

pub fn loggerFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "]: (" ++ @tagName(scope) ++ ") ";
    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr();
    const writer = stderr.writer();

    if (stderr.isTty()) {
        const c = color.Farbe.init().dim();
        nosuspend c.write(writer, prefix ++ format ++ "\n", args) catch return;
    } else {
        nosuspend writer.print(prefix ++ format ++ "\n", args) catch return;
    }
}

/// Print out useful information or help when an execution error occurs.
fn handle_execution_error(writer: anytype, err: anyerror) !void {
    if (utils.inErrorSet(err, commands.Error)) |e| switch (e) {
        commands.Error.NoCommandGiven => {
            try writer.writeAll("No command given.\n\n");
            try help.printHelp(writer);
            std.process.exit(0);
        },
        else => {},
    };
    return err;
}

/// Get the home directory either from an environment variable or determine it
/// relative to the user's home directory
fn get_nkt_home_dir(allocator: std.mem.Allocator) ![]u8 {
    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();
    if (envmap.get("NKT_ROOT_DIR")) |path| {
        return allocator.dupe(u8, path);
    }

    // resolve the home path
    const home_dir_path = envmap.get("HOME").?;
    const root_path = try std.fs.path.join(
        allocator,
        &.{ home_dir_path, ".nkt" },
    );
    return root_path;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    // read arguments
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    // get the root directory of nkt
    const root_path = try get_nkt_home_dir(allocator);
    defer allocator.free(root_path);

    // initialize the file system abstraction
    var fs = try FileSystem.initElseCreate(root_path);
    defer fs.deinit();

    // get the output fd
    const out_fd = std.io.getStdOut();

    // get the local timezone information
    const tz = try time.initTimeZone(allocator);
    defer time.deinitTimeZone();

    try nkt_main(allocator, raw_args, out_fd, tz, fs);

    if (@import("builtin").mode == .Debug) {
        std.log.default.debug("clean exit", .{});
    } else {
        // let the operating system clear up for us
        std.process.exit(0);
    }
}

/// Internal main, seperated from the binary `main` as to allow for use in
/// other programs or in tests
pub fn nkt_main(
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    out_fd: std.fs.File,
    tz: time.TimeZone,
    fs: ?FileSystem,
) !void {
    var arg_iterator = cli.ArgIterator.init(args);
    // skip first arg as is command name
    _ = try arg_iterator.next();

    // read in the root of the topology
    var root = try Root.new(allocator);
    defer root.deinit();

    // give a filesystem handle to the root
    root.fs = fs;

    if (!try handleGenericArguments(root, out_fd.writer(), arg_iterator)) return;

    // execute the command
    commands.execute(
        allocator,
        &arg_iterator,
        root,
        out_fd.writer(),
        out_fd.isTty(),
        tz,
    ) catch |err| {
        try handle_execution_error(out_fd.writer(), err);
    };
}

fn handleGenericArguments(
    _: *Root,
    writer: anytype,
    itt: cli.ArgIterator,
) !bool {
    var dup_itt = itt.copy();
    // discard the name
    _ = try dup_itt.next();

    // loop over all of the arguments once to check for generic arguments
    while (try dup_itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('v', "version")) {
                const opts = @import("options");
                try writer.print("nkt version {d}.{d}.{d}-{s} (schema: {s})\n", .{
                    opts.version.major,
                    opts.version.minor,
                    opts.version.patch,
                    opts.git_hash orelse "[none]",
                    Root.schemaVersion(),
                });
                return false;
            }
            if (arg.is('h', "help")) {
                try @import("commands/help.zig").printHelp(writer);
                return false;
            }
        } else {
            // stop after the first positional argument
            break;
        }
    }
    return true;
}
