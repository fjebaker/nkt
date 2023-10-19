const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");
const DayEntry = @import("DayEntry.zig");
const State = @import("State.zig");
const Editor = @import("Editor.zig");

pub const CommandError = error{ NoCommandGiven, UnknownCommand };

pub const Commands = union(enum) {
    help: @import("commands/help.zig"),
    init: @import("commands/init.zig"),
    list: @import("commands/list.zig"),
    note: @import("commands/note.zig"),

    pub fn run(
        self: *Commands,
        allocator: std.mem.Allocator,
        out_writer: anytype,
        state: *State,
    ) !void {
        switch (self.*) {
            inline else => |*s| try s.run(allocator, out_writer, state),
        }
    }

    pub fn deinit(_: *Commands) void {}

    pub fn init(args: *cli.ArgIterator) !Commands {
        const command = (try args.next()) orelse return CommandError.NoCommandGiven;
        if (command.flag) return CommandError.UnknownCommand;

        inline for (@typeInfo(Commands).Union.fields) |field| {
            if (std.mem.eql(u8, command.string, field.name)) {
                const T = field.type;
                var instance = try @field(T, "init")(args);
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

    var home_dir_path = std.os.getenv("HOME").?;
    var root_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir_path, ".nkt" },
    );
    defer allocator.free(root_path);

    var state: State = .{ .root_path = root_path };
    defer state.deinit();
    try cmd.run(allocator, stdout, &state);

    try bw.flush();
}

test "root" {
    _ = cli;
    _ = DayEntry;
    _ = utils;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
}
