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

pub const short_help = "Compile a note into various formats.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "item",
    "The item to edit (see `help select`).",
    .{ .required = true },
) ++
    &[_]cli.ArgumentDescriptor{
    .{
        .arg = "--open",
        .help = "Open the file after compilation in the configured viewer.",
    },
});

selection: selections.Selection,
open: bool,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);

    const selection = try selections.fromArgs(
        arguments.Parsed,
        args.item,
        args,
    );

    return .{
        .selection = selection,
        .open = args.open,
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

    var item = try self.selection.resolveReportError(root);
    switch (item) {
        .Day, .Task, .Collection, .Entry => {
            return try writer.writeAll("Can only compile notes");
        },
        .Note => |*n| {
            const outpath = try self.compileNote(
                allocator,
                n.note,
                n.directory,
                root,
            );
            defer allocator.free(outpath);
            try writer.print(
                "Compiled '{s}' to '{s}'\n",
                .{ n.note.name, outpath },
            );

            try opts.flushOutput();

            if (self.open) {
                try viewFile(allocator, root, outpath);
            }
        },
    }
}

fn viewFile(allocator: std.mem.Allocator, root: *Root, outpath: []const u8) !void {
    const cmd = root.info.pdf_viewer;
    var list = try std.ArrayList([]const u8).initCapacity(allocator, cmd.len + 1);
    defer list.deinit();

    for (cmd) |c| {
        try list.append(c);
    }
    try list.append(outpath);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    std.log.default.debug("Viewing: '{s}'", .{list.items});

    return std.process.execve(allocator, cmd, &env_map);
}

fn compileNote(
    self: *Self,
    allocator: std.mem.Allocator,
    note: Directory.Note,
    dir: Directory,
    root: *Root,
) ![]const u8 {
    std.log.default.debug("Compiling note: '{s}'", .{note.path});

    _ = self;
    _ = dir;
    const ext = note.getExtension();
    const compiler = root.getTextCompiler(ext) orelse {
        try cli.throwError(
            Root.Error.UnknownExtension,
            "No text compiler for '{s}'",
            .{ext},
        );
        unreachable;
    };

    return try compiler.compileNote(allocator, note, root, .{});
}
