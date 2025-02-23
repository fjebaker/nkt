const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");

const time = @import("topology/time.zig");
const Root = @import("topology/Root.zig");
const cmd_stacks = @import("commands/stacks.zig");

pub const Error = error{ NoCommandGiven, UnknownCommand };

/// Command line argument options that control the input out output sources
pub const Options = struct {
    /// Output is being piped. Contextually this means ANSI escape codes and
    /// interaction will be disabled
    piped: bool = false,

    /// The local timezone for converting dates
    tz: time.TimeZone,

    /// The command or alias typed by the user
    command: []const u8,

    /// An unbuffered writer that can be written to for e.g. interactive
    /// purposes
    unbuffered_writer: T: {
        if (@import("builtin").is_test) {
            break :T std.ArrayList(u8).Writer;
        } else {
            break :T std.fs.File.Writer;
        }
    },
};

pub const Commands = union(enum) {
    chains: @import("commands/chains.zig"),
    compile: @import("commands/compile.zig"),
    config: @import("commands/config.zig"),
    edit: @import("commands/edit.zig"),
    find: @import("commands/find.zig"),
    help: @import("commands/help.zig"),
    import: @import("commands/import.zig"),
    init: @import("commands/init.zig"),
    list: @import("commands/list.zig"),
    log: @import("commands/log.zig"),
    migrate: @import("commands/migrate.zig"),
    new: @import("commands/new.zig"),
    peek: cmd_stacks.Peek,
    pop: cmd_stacks.Pop,
    push: cmd_stacks.Push,
    read: @import("commands/read.zig"),
    remove: @import("commands/remove.zig"),
    rename: @import("commands/rename.zig"),
    select: @import("commands/select.zig"),
    tag: @import("commands/tag.zig"),
    task: @import("commands/task.zig"),
    set: @import("commands/set.zig"),
    // summary: @import("commands/summary.zig"),
    sync: @import("commands/sync.zig"),
    completion: @import("commands/completion.zig"),

    /// Execute the sub command after instatiation.
    pub fn execute(
        self: *Commands,
        allocator: std.mem.Allocator,
        root: *Root,
        out_writer: anytype,
        is_tty: bool,
        tz: time.TimeZone,
        command: []const u8,
    ) !void {
        // create a buffered writer
        var out_buffered = std.io.bufferedWriter(out_writer);
        const out = out_buffered.writer();

        // construct runtime options
        const opts: Options = .{
            .piped = !is_tty,
            .tz = tz,
            .command = command,
            .unbuffered_writer = out_writer,
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
    pub fn initCommand(
        allocator: std.mem.Allocator,
        command: []const u8,
        args: *cli.ArgIterator,
    ) !Commands {
        inline for (@typeInfo(Commands).@"union".fields) |field| {
            const is_field = std.mem.eql(u8, command, field.name);
            const is_alias = utils.isAlias(field, command);
            if (is_field or is_alias) {
                const instance = try @field(field.type, "fromArgs")(
                    allocator,
                    args,
                );
                return @unionInit(Commands, field.name, instance);
            }
        }

        return throwUnknownCommand(command);
    }
};

fn throwUnknownCommand(name: []const u8) anyerror {
    cli.throwError(
        Error.UnknownCommand,
        "'{s}'\n(use 'help' for a list of commands)",
        .{name},
    ) catch |err| return err;
    unreachable;
}

/// Parse argument from the `cli.ArgIterator` and execute the command contained
/// within over the `Root`.
/// Requires auxillary information about where to write output, what timezone
/// we are in for date conversions.
pub fn execute(
    allocator: std.mem.Allocator,
    itt: *cli.ArgIterator,
    root: *Root,
    out_writer: anytype,
    is_tty: bool,
    tz: time.TimeZone,
) !void {
    // an allocator that doesn't need to be tracked by the command
    // allows everything to be freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    // get the command that was typed
    const command = try itt.next() orelse
        return Error.NoCommandGiven;

    if (command.flag) {
        return throwUnknownCommand(command.string);
    }

    var cmd = try Commands.initCommand(alloc, command.string, itt);
    try cmd.execute(alloc, root, out_writer, is_tty, tz, command.string);
}
