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

fn tmpFilePath(allocator: std.mem.Allocator) ![]u8 {
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
    return self.editTemporaryContent(alloc, "");
}

fn writeToFile(path: []const u8, content: []const u8) !void {
    var fs = try std.fs.createFileAbsolute(path, .{});
    defer fs.close();
    try fs.writeAll(content);
}

fn deleteFile(path: []const u8) !void {
    try std.fs.deleteFileAbsolute(path);
}

const MAX_BYTES = @import("FileSystem.zig").MAXIMUM_BYTES_READ;
pub fn editTemporaryContent(self: *Editor, alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    var file_path = try tmpFilePath(alloc);
    defer alloc.free(file_path);

    try writeToFile(file_path, content);

    try self.editPath(file_path);
    defer std.fs.deleteFileAbsolute(file_path) catch {};

    var fs = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
    defer fs.close();

    try deleteFile(file_path);

    return try fs.readToEndAlloc(alloc, MAX_BYTES);
}
