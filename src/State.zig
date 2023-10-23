const std = @import("std");
const utils = @import("utils.zig");

const collections = @import("collections.zig");

pub const CollectionType = collections.CollectionType;
pub const Collection = collections.Collection;
pub const ItemType = collections.ItemType;
pub const Item = collections.Item;

pub const Directory = collections.Directory;
pub const DirectoryItem = collections.DirectoryItem;

pub const Journal = collections.Journal;
pub const JournalItem = collections.JournalItem;

pub const Ordering = collections.Ordering;

// interface for interacting with different not items
// *Entry:     stored by the items representing the underlying note

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

const Self = @This();

pub const Config = struct {
    root_path: []const u8,
};

topology: Topology,
directories: []Directory,
journals: []Journal,
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

    var directories = try collections.newDirectoryList(
        alloc,
        topology.directories,
        fs,
    );
    errdefer alloc.free(directories);

    var journals = try collections.newJournalList(
        alloc,
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
    // update the modified in each journal, and write any read items back to file
    for (self.journals) |*journal| {
        try journal.writeChanges(self.allocator);
    }

    const data = try self.topology.toString(self.allocator);
    defer self.allocator.free(data);

    try self.fs.overwrite(Topology.DATA_STORE_FILENAME, data);
}

pub fn deinit(self: *Self) void {
    for (self.directories) |*f| {
        f.mem.deinit();
        f.content.deinit();
        f.index.deinit();
    }
    for (self.journals) |*f| {
        f.mem.deinit();
        f.content.deinit();
        f.index.deinit();
    }
    self.allocator.free(self.directories);
    self.allocator.free(self.journals);
    self.topology.deinit();
    self.* = undefined;
}

pub fn getDirectory(self: *Self, name: []const u8) ?*Directory {
    for (self.directories) |*f| {
        if (std.mem.eql(u8, f.directory.name, name)) {
            return f;
        }
    }
    return null;
}

pub fn getJournal(self: *Self, name: []const u8) ?*Journal {
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
    var maybe_journal: ?*Journal = null;
    var maybe_directory: ?*Directory = null;

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
