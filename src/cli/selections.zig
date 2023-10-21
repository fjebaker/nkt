const std = @import("std");

const utils = @import("../utils.zig");
const cli = @import("../cli.zig");

const State = @import("../NewState.zig");
const TrackedItem = State.TrackedItem;

const CollectionType = State.CollectionType;
const Date = utils.Date;

fn isNumeric(c: u8) bool {
    return (c >= '0' and c <= '9');
}

fn allNumeric(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c)) return false;
    }
    return true;
}

fn isDate(string: []const u8) bool {
    for (string) |c| {
        if (!isNumeric(c) and c != '-') return false;
    }
    return true;
}

pub const ContainerSelection = struct {
    container: CollectionType,
    name: []const u8,

    pub fn from(container: CollectionType, name: []const u8) ContainerSelection {
        return .{
            .container = container,
            .name = name,
        };
    }
};

pub const SelectionSet = enum {
    ByDateIndex,
    ByDate,
    ByName,
};

pub const Selection = union(enum) {
    ByIndex: struct {
        i: usize,
        date: ?Date = null,
    },
    ByDate: Date,
    ByName: []const u8,

    pub fn today() Selection {
        const date = Date.now();
        return .{ .ByDate = date };
    }

    /// Parse input string into a Selection. Does not validate that the
    /// selection exists.
    pub fn parse(input: []const u8) !Selection {
        if (std.mem.eql(u8, input, "today") or std.mem.eql(u8, input, "t")) {
            return Selection.today();
        } else if (allNumeric(input)) {
            const day = try std.fmt.parseInt(usize, input, 10);
            return .{ .ByDateIndex = .{ .i = day } };
        } else if (isDate(input)) {
            const date = try utils.toDate(input);
            return .{ .Date = date };
        } else {
            return .{ .ByName = input };
        }
    }

    /// Parse ArgIterator into a Selection. Does not validate that the
    /// selection exists. If no positional argument is available, returns null,
    /// allowing caller to set defaults.
    pub fn optionalParse(
        itt: *cli.ArgIterator,
    ) !?Selection {
        const arg = (try itt.next()) orelse return null;
        if (arg.flag) {
            itt.rewind();
            return null;
        }
        return try parse(arg.string);
    }

    /// Caller owns memory
    pub fn asName(self: Selection, collection: anytype, alloc: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .ByDate => |date| return try utils.formatDate(alloc, date),
            .ByName => |name| return try alloc.dupe(u8, name),
            .ByDateIndex => {
                var namelist = try collection.nameList(alloc);
                defer alloc.free(namelist);
            },
        }
    }
};

// pub fn find(state: *State, where: ?ContainerSelection, what: Selection) ?TrackedItem {
//     if (where) |w| switch (w.container) {
//         .Journal => {
//             var journal = state.getJournal(w.where) orelse return null;

//         },
//         .Directory => {

//         }
//     }
//     // both
// }
