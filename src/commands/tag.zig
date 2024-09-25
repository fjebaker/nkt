const std = @import("std");
const cli = @import("../cli.zig");
const ttags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const selections = @import("../selections.zig");
const utils = @import("../utils.zig");

const Root = @import("../topology/Root.zig");
const commands = @import("../commands.zig");

const Self = @This();

pub const short_help = "Tag an item or collection.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(selections.selectHelp(
    "item",
    "The item to edit (see `help select`). If left blank will open an interactive search through the names of the notes.",
    .{ .required = true },
) ++
    &[_]cli.ArgumentDescriptor{.{
    .arg = "@tag1 [@tag2 ...]",
    .help = "The tag (or tags) to assign to the item",
    .parse = false,
}});

selection: selections.Selection,
tags: []const []const u8,

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var tag_list = std.ArrayList([]const u8).init(allocator);
    defer tag_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) try itt.throwUnknownFlag();
            // tag parsing
            const tag_name = ttags.getTagString(arg.string) catch |err| {
                return cli.throwError(err, "{s}", .{arg.string});
            };

            if (tag_name) |name| {
                try tag_list.append(name);
            } else {
                try itt.throwBadArgument("tag format: tags must begin with `@`");
            }
        }
    }

    if (tag_list.items.len == 0) {
        return cli.throwError(
            cli.CLIErrors.TooFewArguments,
            "Must specify at least one @tag to apply to the item.",
            .{},
        );
    }

    const args = try parser.getParsed();
    const selection = try selections.fromArgs(
        arguments.Parsed,
        args.item,
        args,
    );
    return .{
        .tags = try tag_list.toOwnedSlice(),
        .selection = selection,
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    // load the topology
    try root.load();
    var item = try self.selection.resolveReportError(root);
    const new_tags = try utils.parseAndAssertValidTags(
        allocator,
        root,
        null,
        self.tags,
    );
    defer allocator.free(new_tags);
    try item.addTags(new_tags);

    switch (item) {
        .Day => |d| {
            try d.journal.writeDays();
            root.markModified(d.journal.descriptor, .CollectionJournal);
        },
        .Entry => |d| {
            try d.journal.writeDays();
            root.markModified(d.journal.descriptor, .CollectionJournal);
        },
        .Note => |n| {
            root.markModified(n.directory.descriptor, .CollectionDirectory);
        },
        .Task => |t| {
            root.markModified(t.tasklist.descriptor, .CollectionTasklist);
        },
        else => unreachable,
    }

    try root.writeChanges();

    const name = try item.getName(allocator);
    defer allocator.free(name);
    try writer.print("Applied tags to '{s}'\n", .{name});
    _ = opts;
}
