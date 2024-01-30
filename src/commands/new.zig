const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const tags = @import("../tags.zig");

const colors = @import("../colors.zig");

const State = @import("../State.zig");

const Self = @This();

pub const help = "Create a new collection.";
pub const extended_help =
    \\Create a new collection.
    \\  nkt new
    \\     <collection type>     Choice of directory, journal, tasklist, chain, or tag
    \\     <name>                name of the collection
    \\
;

selection: cli.Selection,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    const selected = try cli.Selection.positionalNamedCollection(itt);
    return .{ .selection = selected };
}

pub fn run(self: *Self, state: *State, out_writer: anytype) !void {
    if (self.selection.collection) |collection| {
        const c = try state.newCollection(collection.container, collection.name);
        try state.fs.makeDirIfNotExists(c.getPath());

        try state.writeChanges();
        try out_writer.print(
            "{s} '{s}' created\n",
            .{
                switch (collection.container) {
                    inline else => |i| @tagName(i),
                },
                collection.name,
            },
        );
    } else if (self.selection.tag) |tagname| {
        const info: tags.TagInfo = .{
            .name = tagname,
            .color = colors.randomColor(),
            .created = utils.now(),
        };

        try state.addTagInfo(info);
        try state.writeChanges();

        try out_writer.print(
            "New tag '{s}' created\n",
            .{tagname},
        );
    } else if (self.selection.chain) |chainname| {
        var alloc = state.topology.mem.allocator();
        const new_chain: State.Chain = .{
            .name = chainname,
            .created = utils.now(),
            .active = true,
            .tags = try utils.emptyTagList(alloc),
            .completed = try alloc.alloc(u64, 0),
        };
        try state.addChain(new_chain);
        try state.writeChanges();
        try out_writer.print(
            "New chain '{s}' created\n",
            .{chainname},
        );
    }
}
