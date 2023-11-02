const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const help = "Create a new collection.";
pub const extended_help =
    \\Create a new collection.
    \\  nkt new
    \\     <collection type>     Choice of directory, journal, tasklist
    \\     <name>                name of the collection
    \\
;

collection: cli.selections.CollectionSelection,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    const selected = try cli.Selection.positionalNamedCollection(itt);
    return .{
        .collection = selected.collection.?,
    };
}

pub fn run(self: *Self, state: *State, out_writer: anytype) !void {
    const c = try state.newCollection(self.collection.container, self.collection.name);
    try state.fs.makeDirIfNotExists(c.getPath());

    try state.writeChanges();
    try out_writer.print(
        "{s} '{s}' created\n",
        .{
            switch (self.collection.container) {
                inline else => |i| @tagName(i),
            },
            self.collection.name,
        },
    );
}
