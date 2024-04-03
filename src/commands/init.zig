const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");
const colors = @import("../colors.zig");

const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "(Re)Initialize the home directory structure.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "--reinit",
        .help = "Only create missing files and write missing configuration options.",
    },
    .{
        .arg = "--force",
        .help = "Force initializtion. Danger: this will overwrite *all* topology files.",
    },
});

args: arguments.Parsed,
pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    if (args.reinit and args.force) {
        try itt.throwBadArgument(
            "Cannot specify `--reinit` and `--force`",
        );
        unreachable;
    }
    return .{ .args = args };
}

pub fn execute(
    self: *Self,
    _: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    const topology_exists = try root.fs.?.fileExists("topology.json");

    if (self.args.force) {
        try doInit(writer, root);
        return;
    }

    if (self.args.reinit) {
        if (!topology_exists) {
            try cli.throwError(
                error.NoRootDir,
                "No root topology exists. Cannot reinitialize.",
                .{},
            );
            unreachable;
        }

        try root.load();
        try root.writeRoot();
        return;
    }

    if (topology_exists) {
        try cli.writeFmtd(
            writer,
            "!!! WARNING !!!\n",
            .{},
            colors.RED.bold().fixed(),
            !opts.piped,
        );
        try writer.writeAll(
            \\Home directory topology already exists!
            \\This command will reset all of your collections.
            \\
            \\   Use `--force` to force initialization
            \\
            \\Proceed with caution!
            \\
            \\   Alternative, use `--reinit` to only create missing files.
            \\
            \\
        );
        return;
    } else {
        try doInit(writer, root);
    }
}

fn doInit(writer: anytype, root: *Root) !void {
    // TODO: add a prompt to check if the home directory is correct
    try root.addInitialCollections();
    try root.createFilesystem();
    try writer.print(
        "Home directory initialized: '{s}'\n",
        .{root.fs.?.root_path},
    );
}
