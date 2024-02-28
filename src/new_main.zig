const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");

const Root = @import("topology/Root.zig");
const FileSystem = @import("FileSystem.zig");
const commands = @import("commands.zig");
const Commands = commands.Commands;

const help = @import("commands/help.zig");
const migrate = @import("topology/migrate.zig");

fn parseCommand(
    writer: anytype,
    allocator: std.mem.Allocator,
    itt: *cli.ArgIterator,
    opts: cli.Options,
) !Commands {
    return Commands.init(allocator, itt, opts) catch |err| {
        if (utils.inErrorSet(err, commands.Error)) |e| switch (e) {
            commands.Error.NoCommandGiven => {
                try help.printHelp(writer);
                std.os.exit(0);
            },
            else => {},
        };
        return err;
    };
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

    // get the output fd
    const out_fd = std.io.getStdOut();
    var out_buffered = std.io.bufferedWriter(out_fd.writer());
    var out = out_buffered.writer();

    const opts: cli.Options = .{
        .piped = !out_fd.isTty(),
    };

    // parse the command, use arena allocator so we don't have to be too
    // careful about tracking allocations
    var mem = std.heap.ArenaAllocator.init(allocator);
    defer mem.deinit();

    var cmd = try parseCommand(
        out_fd.writer(),
        mem.allocator(),
        &arg_iterator,
        opts,
    );
    defer cmd.deinit();

    // get the root directory of nkt
    const root_path = try get_nkt_home_dir(allocator);
    defer allocator.free(root_path);
    // initialize the file system abstraction
    var fs = try FileSystem.init(root_path);
    defer fs.deinit();

    var root = Root.new(allocator);
    // give a filesystem handle to the root
    root.fs = fs;
    try cmd.run(&root, out, opts);

    // _ = out;
    // try migrate.migratePath(allocator, root_path);

    // flush the buffered writer so everything gets printed
    try out_buffered.flush();

    if (@import("builtin").mode != .Debug) {
        // let the operating system clear up for us
        std.os.exit(0);
    }
}

test "main" {
    _ = Root;
    _ = cli;
}
