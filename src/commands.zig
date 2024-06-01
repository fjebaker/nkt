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

    buffered_writer: *std.io.BufferedWriter(4096, std.fs.File.Writer),
    // Flush the buffered writer
    pub fn flushOutput(opts: Options) !void {
        try opts.buffered_writer.flush();
    }
};

pub const Commands = union(enum) {
    config: @import("commands/config.zig"),
    compile: @import("commands/compile.zig"),
    chains: @import("commands/chains.zig"),
    edit: @import("commands/edit.zig"),
    find: @import("commands/find.zig"),
    help: @import("commands/help.zig"),
    import: @import("commands/import.zig"),
    init: @import("commands/init.zig"),
    list: @import("commands/list.zig"),
    log: @import("commands/log.zig"),
    new: @import("commands/new.zig"),
    migrate: @import("commands/migrate.zig"),
    read: @import("commands/read.zig"),
    remove: @import("commands/remove.zig"),
    rename: @import("commands/rename.zig"),
    tag: @import("commands/tag.zig"),
    task: @import("commands/task.zig"),
    select: @import("commands/select.zig"),
    set: @import("commands/set.zig"),
    // summary: @import("commands/summary.zig"),
    sync: @import("commands/sync.zig"),
    completion: @import("commands/completion.zig"),

    /// Execute the sub command after instatiation.
    pub fn execute(
        self: *Commands,
        allocator: std.mem.Allocator,
        root: *Root,
        out_fd: anytype,
        tz: time.TimeZone,
    ) !void {

        // create a buffered writer
        var out_buffered = std.io.bufferedWriter(out_fd.writer());
        const out = out_buffered.writer();

        // construct runtime options
        const opts: Options = .{
            .piped = !out_fd.isTty(),
            .tz = tz,
            .buffered_writer = &out_buffered,
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
    /// constructor. This will have implicitly parsed the arguments specific to
    /// that command.
    pub fn init(
        allocator: std.mem.Allocator,
        args: *cli.ArgIterator,
    ) !Commands {
        const command = try args.next() orelse
            return Error.NoCommandGiven;

        if (command.flag) {
            return throwUnknownCommand(command.string);
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

        return throwUnknownCommand(command.string);
    }
};

fn throwUnknownCommand(name: []const u8) anyerror {
    return cli.throwError(
        Error.UnknownCommand,
        "'{s}'\n(use 'help' for a list of commands)",
        .{name},
    );
}

/// Parse argument from the `cli.ArgIterator` and execute the command contained
/// within over the `Root`.
/// Requires auxillary information about where to write output, what timezone
/// we are in for date conversions.
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

    const alloc = arena.allocator();

    var cmd = try Commands.init(alloc, itt);
    try cmd.execute(alloc, root, out_fd, tz);
}
