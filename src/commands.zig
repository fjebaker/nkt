const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");

pub const Error = error{ NoCommandGiven, UnknownCommand };

/// Command line argument options that control the input out output sources
pub const Options = struct {
    /// Output is being piped. Contextually this means ANSI escape codes and
    /// interaction will be disabled
    piped: bool = false,

    /// The local timezone for converting dates
    tz: time.TimeZone,
};

pub const Commands = union(enum) {
    config: @import("commands/config.zig"),
    // chains: @import("commands/chains.zig"),
    // edit: @import("commands/edit.zig"),
    // find: @import("commands/find.zig"),
    help: @import("commands/help.zig"),
    // import: @import("commands/import.zig"),
    // init: @import("commands/init.zig"),
    // list: @import("commands/list.zig"),
    log: @import("commands/log.zig"),
    // new: @import("commands/new.zig"),
    // read: @import("commands/read.zig"),
    // remove: @import("commands/remove.zig"),
    // rename: @import("commands/rename.zig"),
    // task: @import("commands/task.zig"),
    // select: @import("commands/select.zig"),
    // set: @import("commands/set.zig"),
    // summary: @import("commands/summary.zig"),
    // sync: @import("commands/sync.zig"),
    // completion: @import("commands/completion.zig"),

    pub fn execute(
        self: *Commands,
        allocator: std.mem.Allocator,
        root: *Root,
        out_fd: anytype,
        tz: time.TimeZone,
    ) !void {

        // create a buffered writer
        var out_buffered = std.io.bufferedWriter(out_fd.writer());
        var out = out_buffered.writer();

        // construct runtime options
        const opts: Options = .{
            .piped = !out_fd.isTty(),
            .tz = tz,
        };

        switch (self.*) {
            inline else => |*s| try s.execute(
                allocator,
                root,
                out,
                opts,
            ),
        }

        try out_buffered.flush();
    }

    /// Parse a command from the `cli.ArgIterator` and return a `Commands` with
    /// the active field instantiated through calling the `fromArgs`
    /// constructor.
    pub fn init(
        allocator: std.mem.Allocator,
        args: *cli.ArgIterator,
    ) !Commands {
        const command = try args.next() orelse
            return Error.NoCommandGiven;

        if (command.flag) {
            try throwUnknownCommand(command.string);
            unreachable;
        }

        inline for (@typeInfo(Commands).Union.fields) |field| {
            const is_field = std.mem.eql(u8, command.string, field.name);
            const is_alias = utils.isAlias(field, command.string);
            if (is_field or is_alias) {
                const instance = try @field(field.type, "fromArgs")(
                    allocator,
                    args,
                );
                return @unionInit(Commands, field.name, instance);
            }
        }

        try throwUnknownCommand(command.string);
        unreachable;
    }
};

fn throwUnknownCommand(name: []const u8) !void {
    try cli.throwError(
        Error.UnknownCommand,
        "'{s}'\n(use 'help' for a list of commands)",
        .{name},
    );
}

pub fn execute(
    allocator: std.mem.Allocator,
    itt: *cli.ArgIterator,
    root: *Root,
    out_fd: std.fs.File,
    tz: time.TimeZone,
) !void {
    // an allocator that doesn't need to be tracked by the command
    // allows everything to be freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var cmd = try Commands.init(arena.allocator(), itt);
    try cmd.execute(arena.allocator(), root, out_fd, tz);
}
