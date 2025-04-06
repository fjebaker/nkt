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

pub const Arguments = cli.Arguments(selections.selectHelp(
    "item",
    "The item to edit (see `help select`). If left blank will open an interactive search through the names of the notes.",
    .{ .required = true },
) ++
    &[_]cli.ArgumentDescriptor{
        .{
            .arg = "tags",
            .display_name = "@tag1 [@tag2 ...]",
            .help = "The tag (or tags) to assign to the item",
            .parse = false,
        },
        .{
            .arg = "-d/--delete",
            .help = "Delete the tags instead of assigning them. Does not validate that the item has those tags",
        },
    });

selection: selections.Selection,
tags: []const []const u8,
delete: bool,

const StringList = std.ArrayList([]const u8);

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = Arguments.init(itt, .{});

    var tag_list = StringList.init(allocator);
    defer tag_list.deinit();

    const Ctx = struct {
        tags: *StringList,
        fn handleArg(self: *@This(), p: *const Arguments, arg: cli.Arg) anyerror!void {
            if (arg.flag) try p.throwError(cli.CLIErrors.InvalidFlag, "{s}", .{arg.string});
            // tag parsing
            const tag_name = ttags.getTagString(arg.string) catch |err| {
                return cli.throwError(err, "{s}", .{arg.string});
            };

            if (tag_name) |name| {
                try self.tags.append(name);
            } else {
                try p.throwError(
                    cli.CLIErrors.BadArgument,
                    "tag format: tags must begin with `@` (bad: '{s}')",
                    .{arg.string},
                );
            }
        }
    };

    var ctx: Ctx = .{ .tags = &tag_list };
    const args = try parser.parseAllCtx(&ctx, .{ .unhandled_arg = Ctx.handleArg });

    if (tag_list.items.len == 0) {
        try cli.throwError(
            cli.CLIErrors.TooFewArguments,
            "Must specify at least one @tag to apply to the item.",
            .{},
        );
    }

    const selection = try selections.fromArgs(
        Arguments.Parsed,
        args.item,
        args,
    );
    return .{
        .tags = try tag_list.toOwnedSlice(),
        .selection = selection,
        .delete = args.delete,
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

    if (self.delete) {
        try item.removeTags(new_tags);
    } else {
        try item.addTags(new_tags);
    }

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
    if (self.delete) {
        try writer.print("Removed tags from '{s}'\n", .{name});
    } else {
        try writer.print("Applied tags to '{s}'\n", .{name});
    }
    _ = opts;
}
