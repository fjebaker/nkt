const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "Create a new tag or collection.";
pub const long_help = short_help;

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "type",
        .help = "What sort of type to create. Can be 'journal', 'tasklist', 'directory', 'chain' or 'tag'.",
        .required = true,
    },
    .{
        .arg = "name",
        .help = "Name to assign to new object.",
        .required = true,
    },
});

const NewType = enum {
    journal,
    directory,
    tasklist,
    chain,
    tag,
};

ctype: NewType,
name: []const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try arguments.parseAll(itt);

    const ctype = std.meta.stringToEnum(NewType, args.type) orelse {
        try cli.throwError(
            cli.CLIErrors.BadArgument,
            "Not a known type: '{s}'",
            .{args.type},
        );
        unreachable;
    };

    return .{ .ctype = ctype, .name = args.name };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();

    _ = allocator;

    switch (self.ctype) {
        .journal => {
            var c = try root.addNewCollection(self.name, .CollectionJournal);
            defer c.deinit();
        },
        .directory => {
            var c = try root.addNewCollection(self.name, .CollectionDirectory);
            defer c.deinit();
        },
        .tasklist => {
            var c = try root.addNewCollection(self.name, .CollectionTasklist);
            defer c.deinit();
        },
        .chain => {
            try root.addNewChain(.{
                .name = self.name,
                .created = time.timeNow(),
            });
        },
        .tag => {
            try root.addNewTag(tags.Tag.Descriptor.new(self.name));
        },
    }

    try writer.print(
        "New '{s}' created with name '{s}'\n",
        .{ @tagName(self.ctype), self.name },
    );

    switch (self.ctype) {
        .chain => try root.writeChains(opts.tz),
        .tag => try root.writeTags(opts.tz),
        else => try root.writeChanges(opts.tz),
    }
}
