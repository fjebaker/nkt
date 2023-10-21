const std = @import("std");
const utils = @import("utils.zig");

const collections = @import("state/collections.zig");

pub const NotesDirectory = collections.NotesDirectory;
pub const TrackedJournal = collections.TrackedJournal;
pub const ContentMap = collections.ContentMap;
pub const TrackedItem = collections.TrackedItem;
pub const ItemType = collections.ItemType;
pub const Collection = collections.Collection;
pub const CollectionType = collections.CollectionType;
pub const Ordering = collections.Ordering;

const Topology = @import("Topology.zig");
const FileSystem = @import("FileSystem.zig");

const Self = @This();

pub const Config = struct {
    root_path: []const u8,
};

topology: Topology,
directories: []NotesDirectory,
journals: []TrackedJournal,
fs: FileSystem,
allocator: std.mem.Allocator,

fn loadTopologyElseCreate(alloc: std.mem.Allocator, fs: FileSystem) !Topology {
    if (try fs.fileExists(Topology.DATA_STORE_FILENAME)) {
        var data = try fs.readFileAlloc(alloc, Topology.DATA_STORE_FILENAME);
        defer alloc.free(data);
        return try Topology.init(alloc, data);
    } else {
        return try Topology.initNew(alloc);
    }
}

pub fn init(alloc: std.mem.Allocator, config: Config) !Self {
    var fs = try FileSystem.init(config.root_path);
    errdefer fs.deinit();

    var topology = try loadTopologyElseCreate(alloc, fs);
    errdefer topology.deinit();

    var topo_alloc = topology.mem.allocator();

    var directories = try collections.newNotesDirectoryList(
        alloc,
        topo_alloc,
        topology.directories,
        fs,
    );
    errdefer alloc.free(directories);

    var journals = try collections.newTrackedJournalList(
        alloc,
        topo_alloc,
        topology.journals,
        fs,
    );
    errdefer alloc.free(journals);

    return .{
        .topology = topology,
        .directories = directories,
        .journals = journals,
        .fs = fs,
        .allocator = alloc,
    };
}

pub fn writeChanges(self: *Self) !void {
    const data = try self.topology.toString(self.allocator);
    defer self.allocator.free(data);

    try self.fs.overwrite(Topology.DATA_STORE_FILENAME, data);
}

pub fn deinit(self: *Self) void {
    for (self.directories) |*f| {
        f.content.deinit();
        f.index.deinit();
    }
    for (self.journals) |*f| {
        f.index.deinit();
    }
    self.allocator.free(self.directories);
    self.allocator.free(self.journals);
    self.topology.deinit();
    self.* = undefined;
}

pub fn getDirectory(self: *Self, name: []const u8) ?*NotesDirectory {
    for (self.directories) |*f| {
        if (std.mem.eql(u8, f.directory.name, name)) {
            return f;
        }
    }
    return null;
}

pub fn getJournal(self: *Self, name: []const u8) ?*TrackedJournal {
    for (self.journals) |*j| {
        if (std.mem.eql(u8, j.journal.name, name)) {
            return j;
        }
    }
    return null;
}

pub fn getSelectedCollection(self: *Self, collection: CollectionType, name: []const u8) ?Collection {
    return switch (collection) {
        .Journal => .{
            .Journal = self.getJournal(name) orelse return null,
        },
        .Directory => .{
            .Directory = self.getDirectory(name) orelse return null,
        },
        .DirectoryWithJournal => unreachable,
    };
}

pub fn getCollection(self: *Self, name: []const u8) ?Collection {
    var maybe_journal: ?*TrackedJournal = null;
    var maybe_directory: ?*NotesDirectory = null;

    for (self.journals) |*journal| {
        if (std.mem.eql(u8, journal.journal.name, name))
            maybe_journal = journal;
    }

    for (self.directories) |*directory| {
        if (std.mem.eql(u8, directory.directory.name, name))
            maybe_directory = directory;
    }

    return Collection.init(maybe_directory, maybe_journal);
}

pub const CollectionNameList = struct {
    pub const CollectionName = struct {
        collection: CollectionType,
        name: []const u8,
    };

    allocator: std.mem.Allocator,
    items: []CollectionName,

    pub usingnamespace utils.ListMixin(CollectionNameList, CollectionName);
};

pub fn getCollectionNames(
    self: *const Self,
    alloc: std.mem.Allocator,
) !CollectionNameList {
    const N_directories = self.directories.len;
    const N = N_directories + self.topology.journals.len;
    var cnames = try alloc.alloc(CollectionNameList.CollectionName, N);
    errdefer alloc.free(cnames);

    for (0.., self.directories) |i, d| {
        cnames[i] = .{
            .collection = .Directory,
            .name = d.directory.name,
        };
    }

    for (N_directories.., self.journals) |i, j| {
        cnames[i] = .{
            .collection = .Journal,
            .name = j.journal.name,
        };
    }

    return CollectionNameList.initOwned(alloc, cnames);
}
