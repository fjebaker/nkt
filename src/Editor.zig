const std = @import("std");
const Editor = @This();

pub const EditorErrors = error{BadExit};

editor: []const u8,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Editor {
    const editor = std.os.getenv("EDITOR") orelse "vim";
    return .{
        .editor = editor,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Editor) void {
    self.* = undefined;
}

fn tmpFile(allocator: std.mem.Allocator) ![]u8 {
    var prng = std.rand.DefaultPrng.init(0);
    const id_num = prng.random().int(u16);

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try std.fmt.format(list.writer(), "/tmp/.nkt_tmp_file{d:0}", .{id_num});
    return list.toOwnedSlice();
}

fn edit(self: *Editor, filename: []const u8) !void {
    var proc = std.ChildProcess.init(
        &.{ self.editor, filename },
        self.allocator,
    );

    proc.stdin_behavior = std.ChildProcess.StdIo.Inherit;
    proc.stdout_behavior = std.ChildProcess.StdIo.Inherit;
    proc.stderr_behavior = std.ChildProcess.StdIo.Inherit;

    try proc.spawn();
    var term = try proc.wait();
    if (term != .Exited) return EditorErrors.BadExit;
}

pub fn editPath(self: *Editor, path: []const u8) !void {
    try self.edit(path);
}

pub fn editTemporary(self: *Editor, alloc: std.mem.Allocator) ![]u8 {
    var filename = try tmpFile(alloc);
    defer alloc.free(filename);

    try self.edit(self, filename);
    defer std.fs.deleteFileAbsolute(filename) catch {};

    var fs = try std.fs.openFileAbsolute(filename, .{ .mode = .read_only });
    defer fs.close();

    return try fs.readToEndAlloc(alloc, 10_000);
}
