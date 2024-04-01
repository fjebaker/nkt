const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const Finder = @import("../search.zig").Finder;
const Editor = @import("../Editor.zig");
const BlockPrinter = @import("../BlockPrinter.zig");

const Self = @This();

pub const alias = [_][]const u8{ "f", "fp", "fe", "fr", "fo" };

pub const short_help = "Find in notes.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{.{
    .arg = "what",
    .help = "What to search in",
}});

what: ?[]const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);
    return .{
        .what = args.what,
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();
    _ = writer;

    const dirname = root.info.default_directory;

    const dir = (try root.getDirectory(dirname)) orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No such directory '{s}'",
            .{dirname},
        );
        unreachable;
    };

    const paths: [][]const u8 = if (self.what) |p|
        try directoryNotesUnder(
            allocator,
            p,
            dir,
        )
    else
        try getAllPaths(allocator, root);
    defer allocator.free(paths);

    var finder = Finder.init(allocator, root.fs.?.root_path, paths);
    defer finder.deinit();

    const selected = try finder.find() orelse return;

    std.log.default.debug("Selected: {s}:{d}", .{ selected.path, selected.line_number });

    try editFileAt(allocator, root, selected.path, selected.line_number, opts);
}

fn directoryNotesUnder(
    alloc: std.mem.Allocator,
    root: []const u8,
    dir: Directory,
) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(alloc);
    for (dir.info.notes) |note| {
        if (std.mem.startsWith(u8, note.name, root)) {
            try paths.append(note.path);
        }
    }
    return paths.toOwnedSlice();
}

fn getAllPaths(alloc: std.mem.Allocator, root: *Root) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    for (root.info.directories) |d| {
        const dir = (try root.getDirectory(d.name)).?;
        for (dir.info.notes) |note| {
            try paths.append(note.path);
        }
    }

    return try paths.toOwnedSlice();
}

fn editFileAt(
    allocator: std.mem.Allocator,
    root: *Root,
    path: []const u8,
    line: usize,
    _: commands.Options,
) !void {
    if (path.len == 0) return;
    const c_name = utils.inferCollectionName(path).?;
    var dir = (try root.getDirectory(c_name)).?;

    const note_name = std.fs.path.stem(path);

    var note = dir.getNotePtr(note_name).?;
    note.modified = time.Time.now();
    root.markModified(dir.descriptor, .CollectionDirectory);
    try root.writeChanges();

    const abs_path = try root.fs.?.absPathify(allocator, path);
    defer allocator.free(abs_path);

    // this only works for vim
    const line_selector = try std.fmt.allocPrint(
        allocator,
        "+{d}",
        .{line},
    );
    defer allocator.free(line_selector);

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.becomeWithArgs(abs_path, &.{line_selector});
}
