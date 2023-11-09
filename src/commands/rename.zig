const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const alias = [_][]const u8{"mv"};

pub const help = "Move or rename a note, directory, journal, or tasklist.";
pub const extended_help =
    \\Move or rename a note, directory, journal, or tasklist.
    \\
    \\  nkt rename
    \\     <from>
    \\     <to>
    \\
    \\     --from-journal name   name of the journal to move from (else default)
    \\     --to-journal name     name of the journal to move from (else default)
    \\
    \\     --from-tasklist name  name of the tasklist to move from (else default)
    \\     --to-tasklist name    name of the tasklist to move from (else default)
    \\
    \\     --from-dir name       name of the dir to move from (else default)
    \\     --to-dir name         name of the dir to move to (else default)
    \\
;

from: cli.Selection = .{},
to: cli.Selection = .{},

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (try self.from.parseCollectionPrefixed("from-", arg, itt)) continue;
            if (try self.to.parseCollectionPrefixed("to-", arg, itt)) continue;
            return cli.CLIErrors.UnknownFlag;
        } else {
            switch (arg.index.?) {
                1 => try self.from.parseItem(arg),
                2 => try self.to.parseItem(arg),
                else => return cli.CLIErrors.TooManyArguments,
            }
        }
    }

    if (!self.from.validate(.Item) or !self.to.validate(.Item)) {
        return cli.CLIErrors.TooFewArguments;
    }

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var from: State.MaybeItem = (try self.from.find(state)) orelse
        return cli.SelectionError.InvalidSelection;

    // make sure selection resolves to a single item
    if (from.numActive() > 1)
        return cli.SelectionError.AmbiguousSelection;

    const to_collection: cli.selections.CollectionSelection = if (self.to.collection) |col|
        col
    else blk: {
        const collection_name = try from.collectionName();
        const collection_type = try from.collectionType();
        break :blk .{
            .container = collection_type,
            .name = collection_name,
        };
    };

    // ensure the collection types match
    if (try from.collectionType() != to_collection.container)
        return cli.SelectionError.IncompatibleSelection;

    // assert the destination name does not already exist in chosen container
    var destination_collection =
        state.getSelectedCollection(to_collection.container, to_collection.name) orelse
        return cli.SelectionError.InvalidSelection;

    // get the item name, and since we need it later, use the collection's
    // managed memory
    const destination_name =
        try self.to.getItemName(destination_collection.allocator());

    if (destination_collection.get(destination_name)) |_|
        return cli.SelectionError.ChildAlreadyExists;

    // all checks passed, do the rename
    var item = try from.getActive();
    const old_name = try state.allocator.dupe(u8, item.getName());
    defer state.allocator.free(old_name);
    try renameItemCollection(item, destination_name, destination_collection);

    try state.writeChanges();
    try out_writer.print(
        "Renamed '{s}' in '{s} -> '{s}' in '{s}'\n",
        .{
            old_name,
            try from.collectionName(),
            item.getName(),
            to_collection.name,
        },
    );
}

fn renameItemCollection(
    from: State.Item,
    to: []const u8,
    to_collection: *State.Collection,
) !void {
    if (std.mem.eql(u8, from.collectionName(), to_collection.getName())) {
        // only need to rename the item and rename the file
        try from.rename(to);
    } else {
        unreachable; // todo
    }
}
