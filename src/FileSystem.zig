const std = @import("std");
const utils = @import("utils.zig");

const Self = @This();

pub const DIARY_DIRECTORY = "log";
pub const NOTES_DIRECTORY = "notes";

pub const MAXIMUM_BYTES_READ = std.math.pow(usize, 2, 24);

root_path: []const u8,
dir: std.fs.Dir,

pub fn initElseCreate(root_path: []const u8) !Self {
    return Self.init(root_path) catch |err| {
        if (err == error.FileNotFound) {
            try std.fs.makeDirAbsolute(root_path);
            return try Self.init(root_path);
        } else return err;
    };
}

pub fn init(root_path: []const u8) !Self {
    var dir = try std.fs.openDirAbsolute(root_path, .{});
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
    std.log.default.debug("Reading file {s}", .{rel_path});
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

pub fn makeDirIfNotExists(self: *const Self, path: []const u8) !void {
    std.log.default.debug("Creating directory: '{s}'", .{path});
    self.dir.makeDir(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

pub fn openDirElseCreate(self: *const Self, path: []const u8) !std.fs.Dir {
    try self.makeDirIfNotExists(path);
    return try self.dir.openDir(path, .{});
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
        if (err == error.FileNotFound) return false;
        return err;
    };
    return true;
}

pub fn removeFile(self: *const Self, path: []const u8) !void {
    std.log.default.debug("Removing file '{s}'", .{path});
    try self.dir.deleteFile(path);
}

/// Overwrite the contents of a file. Will create the file if it does not exist.
pub fn overwrite(self: *const Self, rel_path: []const u8, content: []const u8) !void {
    std.log.default.debug("Overwriting '{s}'", .{rel_path});
    var fs = try self.openElseCreate(rel_path);
    defer fs.close();
    // seek to start to remove anything that may already be in the file
    try fs.seekTo(0);
    try fs.writeAll(content);
    try fs.setEndPos(content.len);
}

/// Turn a path relative to the root directory into an absolute file path.
/// Caller owns the memory.
pub fn absPathify(
    self: *Self,
    allocator: std.mem.Allocator,
    rel_path: []const u8,
) ![]const u8 {
    const pwd = try self.dir.realpathAlloc(allocator, ".");
    defer allocator.free(pwd);
    return try std.fs.path.join(allocator, &.{ pwd, rel_path });
}

pub fn moveFromCwd(
    self: *Self,
    allocator: std.mem.Allocator,
    cwd_rel_from: []const u8,
    rel_to: []const u8,
) !void {
    const abs_to = try self.absPathify(allocator, rel_to);
    defer allocator.free(abs_to);
    const abs_from = try std.fs.cwd().realpathAlloc(allocator, cwd_rel_from);
    defer allocator.free(abs_from);
    try std.fs.renameAbsolute(abs_from, abs_to);
}

pub fn copyFromCwd(
    self: *Self,
    allocator: std.mem.Allocator,
    cwd_rel_from: []const u8,
    rel_to: []const u8,
) !void {
    const abs_to = try self.absPathify(allocator, rel_to);
    defer allocator.free(abs_to);
    const abs_from = try std.fs.cwd().realpathAlloc(allocator, cwd_rel_from);
    defer allocator.free(abs_from);
    try std.fs.copyFileAbsolute(abs_from, abs_to, .{});
}

/// Get a path to a temporary file. Needs an allocator to generate the
/// filename. Zeros any existing file by the same name before returning.
pub fn tmpFile(allocator: std.mem.Allocator) ![]const u8 {
    const path = try tmpFilePath(allocator);
    errdefer allocator.free(path);

    std.log.default.debug("Making tmp file '{s}'", .{path});

    var f = std.fs.openFileAbsolute(
        path,
        .{ .mode = .write_only },
    ) catch |err| b: {
        if (isFileNotFound(err)) {
            break :b try std.fs.createFileAbsolute(path, .{});
        }
        return err;
    };
    defer f.close();
    try f.seekTo(0);

    return path;
}

fn tmpFilePath(allocator: std.mem.Allocator) ![]const u8 {
    var prng = std.rand.DefaultPrng.init(0);
    const id_num = prng.random().int(u16);

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try std.fmt.format(list.writer(), "/tmp/.nkt_tmp_file{d:0}", .{id_num});
    return list.toOwnedSlice();
}

pub fn move(
    self: *Self,
    rel_from: []const u8,
    rel_to: []const u8,
) !void {
    try self.dir.rename(rel_from, rel_to);
}
