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
    \\     --journal name        name of journal to import to (needs .json)
    \\     --dir name            name of directory to import to (anything)
    \\     --tasklist name       name of tasklist to import to (needs .json)
    \\     --move                move the file instead of copying
    \\
;

paths: ?[][]const u8,
where: ?cli.SelectedCollection,
move: bool = false,

const parseCollection = cli.selections.parseJournalDirectoryItemlistFlag;

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{ .where = null, .paths = null };

    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (try parseCollection(arg, itt, true)) |col| {
                if (self.where != null)
                    return cli.SelectionError.AmbiguousSelection;
                self.where = col;
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
        .Journal, .Tasklist => {
            unreachable; // todo
        },
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
    // assert the destination name does not already exist in chosen container
    if (dir.get(filename) != null)
        return cli.SelectionError.ChildAlreadyExists;

    var note = try dir.Directory.newNote(filename);

    if (self.move) {
        try state.fs.moveFromCwd(
            state.allocator,
            path,
            note.getPath(),
        );
    } else {
        try state.fs.copyFromCwd(
            state.allocator,
            path,
            note.getPath(),
        );
    }

    // try different processing pipelines to make modifications to the import
    const pipeline = (try processDendron(state, &note));
    if (pipeline) |pl| {
        try out_writer.print("- Used {any} pipeline\n", .{pl});
    }

    try out_writer.print(
        "Imported '{s}' into directory '{s}'\n",
        .{
            note.getName(),
            name,
        },
    );
}

const ProcessorPipeline = enum { Dendron };

fn processDendron(state: *State, note: *State.Item) !?ProcessorPipeline {
    var content = try note.Note.read();

    var itt = std.mem.tokenize(u8, content, "\n");

    var map = (try parseKeyValue(state.allocator, &itt)) orelse
        return null;
    defer map.deinit();

    const updated_s = map.get("updated") orelse return null;
    const created_s = map.get("created") orelse return null;

    note.Note.note.modified = try std.fmt.parseInt(u64, updated_s, 10);
    note.Note.note.created = try std.fmt.parseInt(u64, created_s, 10);

    const title = map.get("title") orelse return null;

    const stop = itt.index;
    var new_content = try std.mem.concat(state.allocator, u8, &.{
        "# ",
        title,
        "\n",
        content[stop..],
    });
    defer state.allocator.free(new_content);

    try note.Note.dir.content.put(note.Note.note.name, new_content);
    try state.fs.overwrite(note.getPath(), new_content);

    return .Dendron;
}

const StringStringMap = std.StringHashMap([]const u8);
fn parseKeyValue(
    alloc: std.mem.Allocator,
    itt: *std.mem.TokenIterator(u8, .any),
) !?StringStringMap {
    var map = StringStringMap.init(alloc);
    errdefer map.deinit();

    const first_line = itt.next() orelse return map;
    if (!std.mem.eql(u8, std.mem.trim(u8, first_line, " "), "---")) return map;

    while (itt.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed_line, "---")) break; // reached end
        var line_itt = std.mem.tokenize(u8, trimmed_line, ": ");

        const key = line_itt.next() orelse continue;
        const value = line_itt.next() orelse continue;

        try map.put(key, value);
    }

    return map;
}
