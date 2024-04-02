const std = @import("std");
const cli = @import("cli.zig");
const selections = @import("selections.zig");
const utils = @import("utils.zig");

const Root = @import("topology/Root.zig");
const time = @import("topology/time.zig");
const FileSystem = @import("FileSystem.zig");
const commands = @import("commands.zig");
const Commands = commands.Commands;

const color = @import("colors.zig");

const help = @import("commands/help.zig");

test "main" {
    _ = Root;
    _ = cli;
    _ = selections;
    _ = commands;
    _ = time;
}

// configure logging
pub const std_options: std.Options = .{
    // Define logFn to override the std implementation
    .logFn = loggerFn,
};

pub fn loggerFn(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "]: ";
    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr();
    const writer = stderr.writer();

    if (stderr.isTty()) {
        const c = color.ComptimeFarbe.init().dim();
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

    var root = Root.new(allocator);
    defer root.deinit();
    // give a filesystem handle to the root
    root.fs = fs;

    // execute the command
    commands.execute(allocator, &arg_iterator, &root, out_fd, tz) catch |err| {
        try handle_execution_error(out_fd.writer(), err);
    };
}

const TestState = struct {
    allocator: std.mem.Allocator,
    root: *Root,
    out_fd: std.fs.File,
    tz: time.TimeZone,
};

fn testExecute(
    state: TestState,
    comptime args: []const [:0]const u8,
) !void {
    var arg_iterator = cli.ArgIterator.init(args);
    // no skip first since tests exclude the command name
    try commands.execute(
        state.allocator,
        &arg_iterator,
        state.root,
        state.out_fd,
        state.tz,
    );
}

test "end-to-end" {
    // make a temporary `nkt` instance
    var allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const root_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    // create a place to write the outputs
    var outfile = try tmpdir.dir.createFile("output.log", .{});
    defer outfile.close();

    // always UTC for tests
    const tz = try time.initTimeZone(allocator);
    defer time.deinitTimeZone();

    var fs = try FileSystem.init(root_path);
    defer fs.deinit();

    var root: Root = Root.new(allocator);
    defer root.deinit();
    root.fs = fs;

    const state = TestState{
        .allocator = allocator,
        .root = &root,
        .out_fd = outfile,
        .tz = tz,
    };

    // basic commands work
    try testExecute(state, &.{"help"});
    try testExecute(state, &.{"init"});
    try testExecute(state, &.{"config"});
    try testExecute(state, &.{ "log", "hello world" });
    try testExecute(state, &.{ "new", "tag", "abc" });

    // inline tags
    try testExecute(state, &.{ "log", "hello world @abc" });

    // seperate tags
    try testExecute(state, &.{ "log", "hello", "@abc" });

    // task creation
    try testExecute(state, &.{ "task", "do something", "--due", "monday" });
    try testExecute(state, &.{ "task", "do something", "soon", "--due", "monday" });

    // retrieval
    try testExecute(state, &.{ "ls", "--tasklist", "todo" });
    try testExecute(state, &.{"read"});
}
