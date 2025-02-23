const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");
const colors = @import("../colors.zig");

const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "(Re)Initialize the home directory structure.";
pub const long_help =
    \\(Re)Initialize the home directory structure.
    \\
    \\You can override where the home directory is with the `NKT_ROOT_DIR`
    \\environment variable. Be sure to export it in your shell rc or profile file to
    \\make the change permanent.
    \\
    \\Initializing will create a number of defaults: a directory "notes", a journal
    \\"diary", a tasklist "todo".
    \\
    \\These can be changed later if desired. You must always have some defaults
    \\defined so that nkt knows where to put things if you don't tell it otherwise.
    \\
;

pub const Arguments = cli.Arguments(&.{
    .{
        .arg = "--reinit",
        .help = "Only create missing files and write missing configuration options.",
    },
    .{
        .arg = "--reinit-all",
        .help = "Opens and rewrite the ENTIRE nkt topology system. Useful for reformatting JSON or applying modifications. Not for general use.",
    },
    .{
        .arg = "--force",
        .help = "Force initializtion. Danger: this will overwrite *all* topology files.",
    },
});

args: Arguments.Parsed,
pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = Arguments.init(itt, .{});

    const args = try parser.parseAll();
    if (args.reinit and args.force) {
        try parser.throwError(
            cli.CLIErrors.BadArgument,
            "Cannot specify `--reinit` and `--force`",
            .{},
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

    if (self.args.@"reinit-all") {
        if (!topology_exists) {
            return cli.throwError(
                error.NoRootDir,
                "No root topology exists. Cannot reinitialize.",
                .{},
            );
        }

        try root.load();

        // touch all journals
        for (root.info.journals) |journal_info| {
            var journal = (try root.getJournal(journal_info.name)).?;
            for (journal.getInfo().days) |day| {
                _ = try journal.getEntries(day);
            }
            try journal.writeDays();
            root.markModified(journal_info, .CollectionJournal);
        }
        // touch all directories
        for (root.info.directories) |directory_info| {
            _ = (try root.getDirectory(directory_info.name)).?;
            root.markModified(directory_info, .CollectionDirectory);
        }
        // touch all tasklists
        for (root.info.tasklists) |tasklist_info| {
            _ = (try root.getTasklist(tasklist_info.name)).?;
            root.markModified(tasklist_info, .CollectionTasklist);
        }
        // touch all chains
        _ = try root.getChainList();
        _ = try root.getTagDescriptorList();
        _ = try root.getStackList();
        try root.writeTags();
        try root.writeChains();
        try root.writeChanges();
        try root.writeStacks();
        try root.writeRoot();
        return;
    }

    if (self.args.reinit) {
        if (!topology_exists) {
            return cli.throwError(
                error.NoRootDir,
                "No root topology exists. Cannot reinitialize.",
                .{},
            );
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
            colors.RED.bold(),
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
