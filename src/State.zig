const std = @import("std");
const utils = @import("utils.zig");

const Self = @This();

root_path: []const u8,
dir: ?std.fs.Dir = null,

pub fn getDir(self: *Self) !std.fs.Dir {
    return self.dir orelse {
        self.dir = try std.fs.cwd().openDir(self.root_path, .{});
        return self.dir.?;
    };
}

pub fn openElseCreate(self: *Self, rel_path: []const u8) !std.fs.File {
    var dir = try self.getDir();
    return (try self.openElseNull(rel_path)) orelse
        dir.createFile(rel_path, .{});
}

pub fn openElseNull(self: *Self, rel_path: []const u8) !?std.fs.File {
    var dir = try self.getDir();
    return dir.openFile(rel_path, .{ .mode = .read_write }) catch |err| {
        if (utils.inErrorSet(err, std.fs.File.OpenError)) |e| {
            if (e == std.fs.File.OpenError.FileNotFound) {
                return null;
            }
        }
        return err;
    };
}

pub fn readFileElseNull(
    self: *Self,
    alloc: std.mem.Allocator,
    rel_path: []const u8,
) !?[]u8 {
    var file = (try self.openElseNull(rel_path)) orelse return null;
    defer file.close();
    return try file.readToEndAlloc(alloc, 16384);
}

pub fn readFile(self: *Self, alloc: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    var dir = try self.getDir();
    var file = try dir.openFile(rel_path, .{ .mode = .read_only });
    defer file.close();
    return file.readToEndAlloc(alloc, 16384);
}

pub fn deinit(self: *Self) void {
    if (self.dir) |d| d.close();
    self.* = undefined;
}
