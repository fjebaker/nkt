const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const selections = @import("../cli/selections.zig");
const Commands = @import("../main.zig").Commands;
const State = @import("../State.zig");

pub const help = "(Re)Initialize the home directory structure.";

const Self = @This();

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    if (try itt.next()) |_| return cli.CLIErrors.TooManyArguments;
    return .{};
}

fn makeNewCollection(state: *State, ctype: State.CollectionType, name: []const u8) !void {
    if (state.getSelectedCollection(ctype, name)) |_| {
        return;
    }
    const c = try state.newCollection(ctype, name);
    try state.fs.makeDirIfNotExists(c.getPath());
}

pub fn run(
    _: *Self,
    state: *State,
    _: anytype,
) !void {
    // setup tasklists directory
    if (!try state.fs.fileExists("tasklists")) {
        try state.fs.dir.makeDir("tasklists");
    }

    if (!try state.fs.fileExists("chains.json")) {
        // setup the empty chains file
        var cf = try state.fs.dir.createFile("chains.json", .{});
        try cf.writeAll("{\"chains\":[]}");
        cf.close();
    }

    // setup the root directories
    try makeNewCollection(state, .Directory, selections.DEFAULT_DIRECTORY.name);
    // diary needs both a directory and journal
    try makeNewCollection(state, .Directory, selections.DEFAULT_JOURNAL.name);
    try makeNewCollection(state, .Journal, selections.DEFAULT_JOURNAL.name);
    try makeNewCollection(state, .Tasklist, selections.DEFAULT_TASKLIST.name);

    if (!try state.fs.fileExists("topology.json")) {
        // create an empty topology file
        var tf = try state.fs.openElseCreate("topology.json");
        tf.close();
    }

    // write the topology file
    try state.writeChanges();
}
