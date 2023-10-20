const std = @import("std");
const utils = @import("utils.zig");

const Self = @This();

pub const DIARY_DIRECTORY = "log";
pub const NOTES_DIRECTORY = "notes";

pub const MAXIMUM_BYTES_READ = 16384;

root_path: []const u8,
dir: std.fs.Dir,

pub fn init(root_path: []const u8) !Self {
    var dir = try std.fs.cwd().openDir(root_path, .{});
    errdefer dir.close();

    return .{
        .dir = dir,
        .root_path = root_path,
    };
}

pub fn deinit(self: *Self) void {
    self.dir.close();
    self.* = undefined;
}

fn isFileNotFound(err: anyerror) bool {
    if (utils.inErrorSet(err, std.fs.File.OpenError)) |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            return true;
        }
    }
    return false;
}

/// Open a file at the given relative path, else create it and return handle.
/// Will raise errors for permissions, etc.
pub fn openElseCreate(self: *const Self, rel_path: []const u8) !std.fs.File {
    return (try self.openElseNull(rel_path)) orelse
        self.dir.createFile(rel_path, .{});
}

/// Open a file at the given relative path, else return `null` if the
/// file does not exist. Will raise errors for permissions, etc.
pub fn openElseNull(self: *const Self, rel_path: []const u8) !?std.fs.File {
    return self.dir.openFile(rel_path, .{ .mode = .read_write }) catch |err| {
        if (isFileNotFound(err)) return null;
        return err;
    };
}

/// Read the contents of a file at the relativity path.
/// Caller owns the memory.
pub fn readFileAlloc(
    self: *const Self,
    alloc: std.mem.Allocator,
    rel_path: []const u8,
) ![]u8 {
    var file = try self.dir.openFile(rel_path, .{ .mode = .read_only });
    defer file.close();
    return file.readToEndAlloc(alloc, MAXIMUM_BYTES_READ);
}

/// Read the contents of a file at the relativity path, return null if does
/// not exist. Will raise error on permissions etc.
/// Caller owns the memory.
pub fn readFileAllocElseNull(
    self: *const Self,
    alloc: std.mem.Allocator,
    rel_path: []const u8,
) !?[]u8 {
    return self.readFileAlloc(alloc, rel_path) catch |err| {
        if (isFileNotFound(err)) return null;
        return err;
    };
}

fn makeDirIfNotExists(self: *const Self, path: []const u8) !void {
    self.dir.makeDir(path) catch |err| {
        if (err != std.os.MakeDirError.PathAlreadyExists) return err;
    };
}

/// Initialize the home directory with requisite sub paths.
pub fn setupDefaultDirectory(self: *const Self) !void {
    try self.makeDirIfNotExists(DIARY_DIRECTORY);
    try self.makeDirIfNotExists(NOTES_DIRECTORY);
}

/// Check if a file exists.
/// Will raise error on permissions etc.
pub fn fileExists(self: *const Self, path: []const u8) !bool {
    self.dir.access(path, .{}) catch |err| {
        if (err == std.fs.Dir.AccessError.FileNotFound) return false;
        return err;
    };
    return true;
}

pub fn overwrite(self: *const Self, rel_path: []const u8, content: []const u8) !void {
    var fs = try self.openElseCreate(rel_path);
    defer fs.close();
    // seek to start to remove anything that may already be in the file
    try fs.seekTo(0);
    try fs.writeAll(content);
    try fs.setEndPos(content.len);
}

pub fn iterableDiaryDirectory(self: *const Self) !std.fs.IterableDir {
    return self.dir.openIterableDir(DIARY_DIRECTORY, .{});
}

pub fn iterableNotesDirectory(self: *const Self) !std.fs.IterableDir {
    return self.dir.openIterableDir(NOTES_DIRECTORY, .{});
}

/// Turn a path relative to the root directory into an absolute file path.
/// Caller owns the memory.
pub fn absPathify(
    self: *Self,
    allocator: std.mem.Allocator,
    rel_path: []const u8,
) ![]const u8 {
    return std.fs.path.join(
        allocator,
        &.{ self.root_path, rel_path },
    );
}
