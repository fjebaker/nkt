const std = @import("std");
const cli = @import("cli.zig");

pub fn inErrorSet(err: anyerror, comptime Set: type) ?Set {
    inline for (@typeInfo(Set).ErrorSet.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(anyerror, e.name);
    }
    return null;
}

pub const State = struct {};

pub const CommandError = error{ NoCommandGiven, BadCommand };

pub const Commands = union(enum) {
    help: @import("commands/help.zig"),

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
        if (command.flag) return CommandError.BadCommand;

        inline for (@typeInfo(Commands).Union.fields) |field| {
            if (std.mem.eql(u8, command.string, field.name)) {
                const T = field.type;
                var instance = try @field(T, "init")(args);
                return @unionInit(Commands, field.name, instance);
            }
        }
        return CommandError.BadCommand;
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
        if (inErrorSet(err, CommandError)) |e| switch (e) {
            CommandError.NoCommandGiven => {
                try @import("./commands/help.zig").print_help(stdout_file);
                std.os.exit(0);
            },
            else => return e,
        };
        return err;
    };
    defer cmd.deinit();

    var state: State = .{};

    try cmd.run(allocator, stdout, &state);

    try bw.flush();
}

test "root" {
    _ = cli;
}
