const std = @import("std");
const cli = @import("cli.zig");
const selections = @import("selections.zig");
const utils = @import("utils.zig");

const Root = @import("topology/Root.zig");
const time = @import("topology/time.zig");
const FileSystem = @import("FileSystem.zig");
const commands = @import("commands.zig");
const Commands = commands.Commands;

const help = @import("commands/help.zig");

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
    var tz = try time.getTimeZone(allocator);
    defer tz.deinit();

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

test "main" {
    _ = Root;
    _ = cli;
    _ = selections;
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
    var tz = try time.TimeZone.initUTC(allocator);
    defer tz.deinit();

    var fs = try FileSystem.init(root_path);
    defer fs.deinit();

    var root: Root = Root.new(allocator);
    root.fs = fs;

    const state = TestState{
        .allocator = allocator,
        .root = &root,
        .out_fd = outfile,
        .tz = tz,
    };

    // basic commands work
    try testExecute(state, &.{"help"});
    try testExecute(state, &.{"config"});
}
