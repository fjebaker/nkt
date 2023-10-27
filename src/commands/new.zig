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
    var p1 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;
    var p2 = (try itt.nextPositional()) orelse return cli.CLIErrors.TooFewArguments;

    var collection_type: State.CollectionType = if (std.mem.eql(u8, "journal", p1.string))
        .Journal
    else if (std.mem.eql(u8, "directory", p1.string))
        .Directory
    else if (std.mem.eql(u8, "tasklist", p1.string))
        .TaskList
    else
        return cli.CLIErrors.BadArgument;
    var name = p2.string;

    return .{ .collection_type = collection_type, .name = name };
}

pub fn run(self: *Self, state: *State, out_writer: anytype) !void {
    if (self.collection_type == .DirectoryWithJournal) return cli.CLIErrors.BadArgument;

    _ = try state.newCollection(self.collection_type, self.name);

    try out_writer.print(
        "Created new {s} named '{s}'\n",
        .{
            switch (self.collection_type) {
                inline else => |i| @tagName(i),
            },
            self.name,
        },
    );
}
