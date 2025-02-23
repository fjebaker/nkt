const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");
const stacks = @import("../topology/stacks.zig");

const Self = @This();

pub const short_help = "Create a new tag or collection.";
pub const long_help =
    \\Create a new tag or collection.
    \\
    \\Note: This cannot be used to create a new note, journal entry, or task.
    \\To create a new note in a notes directory, use `edit --new`. A new journal
    \\entry is automatically created with `log`. Tasks can be manipulated with
    \\`task`.
;

pub const Arguments = cli.Arguments(&.{
    .{
        .arg = "type",
        .help = "What sort of collection type to create. Can be 'journal', 'tasklist', 'directory', 'chain', 'stack' or 'tag'.",
        .required = true,
        .completion = "{compadd journal tasklist directory stack chain tag}",
    },
    .{
        .arg = "name",
        .help = "Name to assign to new collection.",
        .required = true,
    },
});

const NewType = enum {
    journal,
    directory,
    tasklist,
    chain,
    tag,
    stack,
};

ctype: NewType,
name: []const u8,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});

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
    _: commands.Options,
) !void {
    try root.load();

    _ = allocator;

    switch (self.ctype) {
        .journal => {
            _ = try root.addNewCollection(self.name, .CollectionJournal);
        },
        .directory => {
            _ = try root.addNewCollection(self.name, .CollectionDirectory);
        },
        .tasklist => {
            _ = try root.addNewCollection(self.name, .CollectionTasklist);
        },
        .chain => {
            try root.addNewChain(.{
                .name = self.name,
                .created = time.Time.now(),
            });
        },
        .tag => {
            try root.addNewTag(tags.Tag.Descriptor.new(self.name));
        },
        .stack => {
            try root.addNewStack(stacks.Stack.new(self.name));
        },
    }

    switch (self.ctype) {
        .chain => try root.writeChains(),
        .stack => try root.writeStacks(),
        .tag => try root.writeTags(),
        else => try root.writeChanges(),
    }
    try root.writeRoot();

    try writer.print(
        "New '{s}' created with name '{s}'\n",
        .{ @tagName(self.ctype), self.name },
    );
}
