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

collection_type: State.CollectionType,
name: []const u8,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const selected = try cli.selections.getSelectedCollectionPositional(itt);
    return .{ .collection_type = selected.container, .name = selected.name };
}

pub fn run(self: *Self, state: *State, out_writer: anytype) !void {
    if (self.collection_type == .DirectoryWithJournal) return cli.CLIErrors.BadArgument;

    const c = try state.newCollection(self.collection_type, self.name);
    try state.fs.makeDirIfNotExists(c.getPath());

    try out_writer.print(
        "{s} '{s}' created\n",
        .{
            switch (self.collection_type) {
                inline else => |i| @tagName(i),
            },
            self.name,
        },
    );
}
