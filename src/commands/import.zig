const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{"imp"};

pub const help = "Import a note, journal, or tasklist.";
pub const extended_help =
    \\Import a note, journal, or tasklist. Creates te appropriate entries in
    \\the topology file
    \\
    \\  nkt import
    \\     <path>                path to the file to import. defaults to
    \\     [path...]               importing to the default directory. can
    \\                             specificy multiple paths
    \\     [--journal name]      name of journal to import to (needs .json)
    \\     [--dir name]          name of directory to import to (anything)
    \\     [--tasklist name]     name of tasklist to import to (needs .json)
    \\     [--move]              move the file instead of copying
    \\
;

paths: ?[][]const u8,
where: ?cli.SelectedCollection,
move: bool = false,

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{ .where = null, .paths = null };

    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "journal")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(
                        .Journal,
                        value.string,
                    );
                }
            } else if (arg.is(null, "dir") or arg.is(null, "directory")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(
                        .Directory,
                        value.string,
                    );
                }
            } else if (arg.is(null, "tasklist")) {
                if (self.where == null) {
                    const value = try itt.getValue();
                    self.where = cli.SelectedCollection.from(
                        .TaskList,
                        value.string,
                    );
                }
            } else if (arg.is(null, "move")) {
                self.move = true;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            try paths.append(arg.string);
        }
    }

    self.paths = try paths.toOwnedSlice();
    if (self.paths.?.len == 0) return cli.CLIErrors.TooFewArguments;
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const where = self.where orelse
        cli.SelectedCollection{ .container = .Directory, .name = "notes" };
    switch (where.container) {
        .Directory => {
            for (self.paths.?) |path| {
                try self.importToDirectory(path, where.name, state, out_writer);
            }
        },
        .Journal, .TaskList => {
            unreachable; // todo
        },
        .DirectoryWithJournal => unreachable,
    }
}

fn importToDirectory(
    self: *Self,
    path: []const u8,
    name: []const u8,
    state: *State,
    out_writer: anytype,
) !void {
    const ext = std.fs.path.extension(path);
    var filename = std.fs.path.stem(path);

    if (!std.mem.eql(u8, ext, ".md")) {
        if (ext.len != 0) return cli.CLIErrors.BadArgument;
    }

    var dir = state.getDirectory(name) orelse
        return cli.SelectionError.NoSuchDirectory;
    const child = try dir.newChild(filename);

    if (self.move) {
        try state.fs.move(
            state.allocator,
            path,
            child.item.getPath(),
        );
    } else {
        try state.fs.copy(
            state.allocator,
            path,
            child.item.getPath(),
        );
    }

    try out_writer.print(
        "Imported '{s}' into directory '{s}'\n",
        .{
            child.item.getName(),
            name,
        },
    );
}
