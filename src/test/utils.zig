const std = @import("std");
const cli = @import("../cli.zig");
const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");
const time = @import("../topology/time.zig");
const FileSystem = @import("../FileSystem.zig");

pub const TestState = struct {
    allocator: std.mem.Allocator,
    tmpdir: std.testing.TmpDir,
    fs: FileSystem,
    root_path: []const u8,
    root: *Root,
    stdout: std.ArrayList(u8),
    tz: time.TimeZone,

    pub fn deinit(self: *TestState) void {
        self.root.deinit();
        self.fs.deinit();
        self.stdout.deinit();
        self.allocator.free(self.root_path);
        self.tmpdir.cleanup();
        time.deinitTimeZone();
    }

    pub fn init() !TestState {
        // make a temporary `nkt` instance
        var allocator = std.testing.allocator;
        var tmpdir = std.testing.tmpDir(.{});
        errdefer tmpdir.cleanup();

        const root_path = try tmpdir.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(root_path);

        // always UTC for tests
        const tz = try time.initTimeZone(allocator);
        errdefer time.deinitTimeZone();

        var fs = try FileSystem.init(root_path);
        errdefer fs.deinit();

        var root = try Root.new(allocator);
        errdefer root.deinit();
        root.fs = fs;

        return .{
            .tmpdir = tmpdir,
            .allocator = allocator,
            .fs = fs,
            .root = root,
            .root_path = root_path,
            .stdout = std.ArrayList(u8).init(std.testing.allocator),
            .tz = tz,
        };
    }

    /// Clear the output buffer
    pub fn clearOutput(self: *TestState) void {
        self.stdout.clearRetainingCapacity();
    }

    /// Write contents to a given file (to simulate having edited content in a
    /// certain way).
    pub fn writeToFile(
        self: *TestState,
        path: []const u8,
        content: []const u8,
    ) !void {
        try self.fs.overwrite(path, content);
    }
};

pub fn testExecute(
    state: *TestState,
    comptime args: []const [:0]const u8,
) !void {
    var arg_iterator = cli.ArgIterator.init(args);
    // no skip first since tests exclude the command name
    try commands.execute(
        state.allocator,
        &arg_iterator,
        state.root,
        state.stdout.writer(),
        false,
        state.tz,
    );
}

pub fn testExecuteExpectOutput(
    state: *TestState,
    comptime args: []const [:0]const u8,
    comptime output: []const u8,
) !void {
    // clear whatever is in the output buffer
    state.stdout.clearRetainingCapacity();
    var arg_iterator = cli.ArgIterator.init(args);
    // no skip first since tests exclude the command name
    try commands.execute(
        state.allocator,
        &arg_iterator,
        &state.root,
        state.stdout.writer(),
        false,
        state.tz,
    );

    try std.testing.expectEqualStrings(output, state.stdout.items);
}
