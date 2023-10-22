const std = @import("std");

const cli = @import("cli.zig");
const utils = @import("utils.zig");

const State = @import("NewState.zig");

pub const CommandError = error{ NoCommandGiven, UnknownCommand };

pub const Commands = union(enum) {
    // edit: @import("commands/edit.zig"),
    help: @import("commands/help.zig"),
    init: @import("commands/init.zig"),
    list: @import("commands/list.zig"),
    note: @import("commands/note.zig"),
    read: @import("commands/read.zig"),

    pub fn run(
        self: *Commands,
        state: *State,
        out_writer: anytype,
    ) !void {
        switch (self.*) {
            inline else => |*s| try s.run(state, out_writer),
        }
    }

    pub fn deinit(_: *Commands) void {}

    pub fn init(args: *cli.ArgIterator) !Commands {
        const command = try args.next() orelse
            return CommandError.NoCommandGiven;

        if (command.flag) return CommandError.UnknownCommand;

        inline for (@typeInfo(Commands).Union.fields) |field| {
            const is_field = std.mem.eql(u8, command.string, field.name);
            const is_alias = utils.isAlias(field, command.string);
            if (is_field or is_alias) {
                var instance = try @field(field.type, "init")(args);
                return @unionInit(Commands, field.name, instance);
            }
        }
        return CommandError.UnknownCommand;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var arg_iterator = cli.ArgIterator.init(raw_args);
    // skip first arg as is command name
    _ = try arg_iterator.next();

    var cmd = Commands.init(&arg_iterator) catch |err| {
        if (utils.inErrorSet(err, CommandError)) |e| switch (e) {
            CommandError.NoCommandGiven => {
                try @import("./commands/help.zig").printHelp(stdout_file);
                std.os.exit(0);
            },
            else => return e,
        };
        return err;
    };
    defer cmd.deinit();

    // resolve the home path
    var home_dir_path = std.os.getenv("HOME").?;
    var root_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir_path, ".nkt" },
    );
    defer allocator.free(root_path);

    // initialize the state
    var state = try State.init(
        allocator,
        .{ .root_path = root_path },
    );
    defer state.deinit();

    // setup complete: execute the program
    try cmd.run(&state, stdout);

    try state.writeChanges();

    try bw.flush();
}

test "root" {
    _ = cli;
    _ = utils;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
}
