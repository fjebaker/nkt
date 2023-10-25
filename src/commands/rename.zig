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
    \\     <from>                path to the file to import. defaults to
    \\     <to>                  importing to the default directory. can
    \\                             specificy multiple paths
    \\     [--from-journal name] name of the journal to move from (else default)
    \\     [--to-journal name]   name of the journal to move from (else default)
    \\     [--from-dir name]     name of the dir to move from (else default)
    \\     [--to-dir name]       name of the dir to move to (else default)
    \\
;

from: ?[]const u8 = null,
to: ?[]const u8 = null,
from_where: ?cli.SelectedCollection = null,
to_where: ?cli.SelectedCollection = null,

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var self: Self = .{};

    var paths = std.ArrayList([]const u8).init(alloc);
    errdefer paths.deinit();

    itt.counter = 0;
    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is(null, "--from-journal")) {
                if (self.from_where != null) return cli.CLIErrors.InvalidFlag;
                self.from_where = .{
                    .container = .Journal,
                    .name = (try itt.getValue()).string,
                };
            } else if (arg.is(null, "--from-dir") or arg.is(null, "--from-directory")) {
                if (self.from_where != null) return cli.CLIErrors.InvalidFlag;
                self.from_where = .{
                    .container = .Directory,
                    .name = (try itt.getValue()).string,
                };
            } else if (arg.is(null, "--to-dir") or arg.is(null, "--to-directory")) {
                if (self.to_where != null) return cli.CLIErrors.InvalidFlag;
                self.to_where = .{
                    .container = .Directory,
                    .name = (try itt.getValue()).string,
                };
            } else if (arg.is(null, "--to-journal")) {
                if (self.to_where != null) return cli.CLIErrors.InvalidFlag;
                self.to_where = .{
                    .container = .Journal,
                    .name = (try itt.getValue()).string,
                };
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (arg.index.? > 2) return cli.CLIErrors.TooManyArguments;
            if (self.from == null)
                self.from = arg.string
            else
                self.to = arg.string;
        }
    }

    if (self.from == null or self.to == null) {
        return cli.CLIErrors.TooFewArguments;
    }

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    var from = cli.find(
        state,
        self.from_where,
        .{ .ByName = self.from.? },
    ) orelse
        return cli.SelectionError.InvalidSelection;
    const to_where: cli.selections.SelectedCollection = self.to_where orelse blk: {
        const collection_name = from.collectionName();
        const collection_type = from.collectionType();
        break :blk .{
            .container = collection_type,
            .name = collection_name,
        };
    };

    if (from.collectionType() != to_where.container)
        return cli.SelectionError.IncompatibleSelection;

    // assert the destination name does not already exist in chosen container
    var dest = state.getSelectedCollection(to_where.container, to_where.name) orelse
        return cli.SelectionError.InvalidSelection;
    if (dest.hasChildName(self.to.?))
        return cli.SelectionError.ChildAlreadyExists;

    switch (from) {
        .Note => |*note| {
            if (std.mem.eql(u8, from.collectionName(), to_where.name)) {
                // only need to rename the item and rename the file
                try note.rename(self.to.?);
                try out_writer.print(
                    "Renamed '{s}' in '{s} -> '{s}' in '{s}'\n",
                    .{
                        self.from.?,
                        from.collectionName(),
                        note.item.getName(),
                        to_where.name,
                    },
                );
            } else {
                unreachable; // todo
            }
        },
        else => unreachable,
    }
}
