const std = @import("std");
const FileSystem = @import("FileSystem.zig");
const Editor = @This();

pub const EditorErrors = error{BadExit};

editor: []const u8,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Editor {
    var envmap = try std.process.getEnvMap(allocator);
    defer envmap.deinit();
    const editor = try allocator.dupe(u8, envmap.get("EDITOR") orelse "nano");

    return .{
        .editor = editor,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Editor) void {
    self.allocator.free(self.editor);
    self.* = undefined;
}

fn edit(self: *Editor, filename: []const u8) !void {
    try self.editWithArgs(filename, &.{});
}

fn assemble_args(alloc: std.mem.Allocator, editor: []const u8, filename: []const u8, args: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    errdefer list.deinit();
    try list.append(editor);
    for (args) |arg| try list.append(arg);
    try list.append(filename);
    return list.toOwnedSlice();
}

fn editWithArgs(
    self: *Editor,
    filename: []const u8,
    args: []const []const u8,
) !void {
    const all_args = try assemble_args(self.allocator, self.editor, filename, args);
    defer self.allocator.free(all_args);

    var proc = std.process.Child.init(
        all_args,
        self.allocator,
    );

    proc.stdin_behavior = std.process.Child.StdIo.Inherit;
    proc.stdout_behavior = std.process.Child.StdIo.Inherit;
    proc.stderr_behavior = std.process.Child.StdIo.Inherit;

    try proc.spawn();
    const term = try proc.wait();
    if (term != .Exited) return EditorErrors.BadExit;
}

pub fn editPath(self: *Editor, path: []const u8) !void {
    try self.edit(path);
}

pub fn becomeWithArgs(self: *Editor, path: []const u8, args: []const []const u8) !void {
    std.log.default.debug("Becoming editor: path '{s}'", .{path});
    const all_args = try assemble_args(self.allocator, self.editor, path, args);
    defer self.allocator.free(all_args);

    var env_map = try std.process.getEnvMap(self.allocator);
    defer env_map.deinit();

    if (@import("builtin").is_test) {
        return error.NoExecveInTest;
    }

    return std.process.execve(self.allocator, all_args, &env_map);
}

pub fn editPathArgs(self: *Editor, path: []const u8, args: []const []const u8) !void {
    try self.editWithArgs(path, args);
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
    const file_path = try FileSystem.tmpFile(alloc);
    defer alloc.free(file_path);

    try writeToFile(file_path, content);

    try self.editPath(file_path);
    defer std.fs.deleteFileAbsolute(file_path) catch {};

    var fs = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
    defer fs.close();

    try deleteFile(file_path);

    return try fs.readToEndAlloc(alloc, MAX_BYTES);
}
