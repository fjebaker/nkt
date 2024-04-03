const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const FileSystem = @import("../FileSystem.zig");
const Directory = @import("../topology/Directory.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();
const Error = error{UnknownNoteType};

pub const alias = [_][]const u8{"imp"};

pub const short_help = "Import a note.";
pub const long_help =
    \\Import a note, journal, or tasklist. Creates te appropriate entries in
    \\the topology file
;

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "path",
        .help = "Path(s) to the files to import, seperated by spaces. Can optionally specify a new name for each note by appending `:name`, such as `recipe.cake.md:recipe.chocolate-cake`.",
        .display_name = "paths[:name] [path[:name] ...]",
        .parse = false,
    },
    .{
        .arg = "--directory name",
        .help = "The directory to import the note into. Default: default directory.",
    },
    .{
        .arg = "--ext extension",
        .help = "The file extension for the new note. Will otherwise use the filename to determine the extension. Note: specifying the extension will apply this extension to all notes imported.",
    },
    .{
        .arg = "--move",
        .help = "Move the file instead of copying. That is to say, will remove the original and keep only the transformed nkt note.",
    },
    .{
        .arg = "--type name",
        .help = "The type of note to import. Currently only supports 'dendron' to process dendron frontmatter. If not supplied, will not attempt to parse any parts of the note.",
    },
});

paths: []const []const u8,
names: []const []const u8,
directory: ?[]const u8,
move: bool = false,
ext: ?[]const u8,
note_type: ?[]const u8,

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var names_list = std.ArrayList([]const u8).init(allocator);
    defer names_list.deinit();

    var paths_list = std.ArrayList([]const u8).init(allocator);
    defer paths_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) {
                try itt.throwUnknownFlag();
            } else {
                if (std.mem.indexOfScalar(u8, arg.string, ':')) |i| {
                    const path = arg.string[0..i];
                    const name = arg.string[i + 1 ..];
                    if (name.len < 1) {
                        try itt.throwBadArgument("Note name too short");
                    }
                    try names_list.append(name);
                    try paths_list.append(path);
                } else {
                    try names_list.append(std.fs.path.stem(arg.string));
                    try paths_list.append(arg.string);
                }
            }
        }
    }

    if (paths_list.items.len == 0) {
        try itt.throwTooFewArguments("path");
    }

    const parsed = try parser.getParsed();

    return .{
        .paths = try paths_list.toOwnedSlice(),
        .names = try names_list.toOwnedSlice(),
        .directory = parsed.directory,
        .move = parsed.move,
        .ext = parsed.ext,
        .note_type = parsed.type,
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

    const dir_name = self.directory orelse root.info.default_directory;

    var dir = (try root.getDirectory(dir_name)) orelse {
        try cli.throwError(
            Root.Error.NoSuchCollection,
            "No directory with name '{s}'",
            .{dir_name},
        );
        unreachable;
    };

    const nt = parseNoteType(self.note_type) catch {
        try cli.throwError(
            Error.UnknownNoteType,
            "Note type to import unknown: '{s}'",
            .{dir_name},
        );
        unreachable;
    };

    root.markModified(dir.descriptor, .CollectionDirectory);
    for (self.paths, self.names) |path, name| {
        const ext = self.ext orelse std.fs.path.extension(path);
        try self.importNote(
            allocator,
            name,
            path,
            &dir,
            root,
            ext,
            nt,
        );

        try writer.print(
            "Imported '{s}' to '{s}'\n",
            .{ name, dir.descriptor.name },
        );
        try opts.flushOutput();
    }

    try root.writeChanges();
}

const NoteType = enum {
    none,
    dendron,
};

fn parseNoteType(string: ?[]const u8) Error!NoteType {
    if (string) |s| {
        return std.meta.stringToEnum(NoteType, s) orelse
            return Error.UnknownNoteType;
    } else return .none;
}

fn importNote(
    self: *Self,
    allocator: std.mem.Allocator,
    note_name: []const u8,
    path: []const u8,
    dir: *Directory,
    root: *Root,
    ext: []const u8,
    nt: NoteType,
) !void {
    std.log.default.debug(
        "Importing '{s}' to '{s}': ext '{s}'",
        .{ note_name, dir.descriptor.name, ext },
    );

    var note = dir.addNewNoteByName(
        note_name,
        .{ .extension = ext },
    ) catch |err| {
        try cli.throwError(err, "cannot import note.", .{});
        unreachable;
    };

    if (self.move) {
        const abs_new_path = try root.fs.?.absPathify(
            allocator,
            note.path,
        );
        defer allocator.free(abs_new_path);
        try std.fs.cwd().rename(
            path,
            abs_new_path,
        );
    } else {
        try std.fs.cwd().copyFile(path, root.fs.?.dir, note.path, .{});
    }

    // no further processing needed
    if (nt == .none) return;

    const content = try dir.readNote(allocator, note);
    defer allocator.free(content);

    var itt = std.mem.tokenize(u8, content, "\n");

    switch (nt) {
        .none => unreachable,
        .dendron => {
            std.log.default.debug(
                "Parsing '{s}' as dendron",
                .{note.name},
            );

            var map = try parseKeyValue(allocator, &itt);
            defer map.deinit();

            note.modified = getTime(map, "updated") orelse note.modified;
            note.created = getTime(map, "created") orelse note.created;

            const title = map.get("title") orelse note.name;

            const new_content = try std.mem.concat(
                allocator,
                u8,
                &.{ "# ", title, "\n", content[itt.index..] },
            );
            defer allocator.free(new_content);

            try root.fs.?.overwrite(note.path, new_content);
        },
    }
}

fn getTime(map: StringStringMap, key: []const u8) ?time.Time {
    const string = map.get(key) orelse {
        std.log.default.warn(
            "Dendron: no key '{s}'",
            .{key},
        );
        return null;
    };
    const t = std.fmt.parseInt(u64, string, 10) catch {
        std.log.default.warn(
            "Dendron: failed to parse '{s}'",
            .{key},
        );
        return null;
    };

    return time.Time.timeFromMilisUK(t);
}

const StringStringMap = std.StringHashMap([]const u8);
fn parseKeyValue(
    alloc: std.mem.Allocator,
    itt: *std.mem.TokenIterator(u8, .any),
) !StringStringMap {
    var map = StringStringMap.init(alloc);
    errdefer map.deinit();

    const first_line = itt.next() orelse return map;
    if (!std.mem.eql(u8, trim(first_line), "---")) return map;

    while (itt.next()) |line| {
        const trimmed_line = trim(line);
        if (std.mem.eql(u8, trimmed_line, "---")) break; // reached end

        const index = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse {
            std.log.default.debug(
                "Dendron: could not parse '{s}'",
                .{trimmed_line},
            );
            continue;
        };

        const key = trim(trimmed_line[0..index]);
        const value = trim(trimmed_line[index + 1 ..]);

        try map.put(key, value);
    }

    return map;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}
