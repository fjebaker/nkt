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

    var arg_iterator = cli.ArgIterator.init(raw_args);
    // skip first arg as is command name
    _ = try arg_iterator.next();

    // get the root directory of nkt
    const root_path = try get_nkt_home_dir(allocator);
    defer allocator.free(root_path);

    // initialize the file system abstraction
    var fs = try FileSystem.init(root_path);
    defer fs.deinit();

    var root = Root.new(allocator);
    // give a filesystem handle to the root
    root.fs = fs;

    // get the output fd
    const out_fd = std.io.getStdOut();

    // get the local timezone information
    var tz = try time.getTimeZone(allocator);
    defer tz.deinit();

    // execute the command
    commands.execute(allocator, &arg_iterator, &root, out_fd, tz) catch |err| {
        try handle_execution_error(out_fd.writer(), err);
    };

    // _ = out;
    // try migrate.migratePath(allocator, root_path);

    if (@import("builtin").mode != .Debug) {
        // let the operating system clear up for us
        std.os.exit(0);
    }
}

test "main" {
    _ = Root;
    _ = cli;
    _ = selections;
}
