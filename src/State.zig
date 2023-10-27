const std = @import("std");
const utils = @import("utils.zig");

const collections = @import("collections.zig");

pub const CollectionType = collections.CollectionType;
pub const Collection = collections.Collection;
pub const ItemType = collections.ItemType;
pub const Item = collections.Item;

pub const Directory = collections.Directory;
pub const Journal = collections.Journal;
pub const TaskList = collections.TaskList;

pub const DirectoryItem = collections.DirectoryItem;
pub const JournalItem = collections.JournalItem;
pub const TaskListItem = collections.TaskListItem;

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
tasklists: []TaskList,
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

    var tasklists = try collections.newTaskListList(
        alloc,
        topology.tasklists,
        fs,
    );
    errdefer alloc.free(tasklists);

    return .{
        .topology = topology,
        .directories = directories,
        .tasklists = tasklists,
        .journals = journals,
        .fs = fs,
        .allocator = alloc,
    };
}

pub fn writeChanges(self: *Self) !void {
    // update the modified in each journal, and write any read items back to file
    for (self.journals) |*journal| {
        try collections.writeChanges(journal, self.allocator);
    }

    const data = try self.topology.toString(self.allocator);
    defer self.allocator.free(data);

    try self.fs.overwrite(Topology.DATA_STORE_FILENAME, data);
}

pub fn deinit(self: *Self) void {
    for (self.directories) |*f| {
        f.deinit();
    }
    for (self.journals) |*f| {
        f.deinit();
    }
    for (self.tasklists) |*f| {
        f.deinit();
    }
    self.allocator.free(self.directories);
    self.allocator.free(self.journals);
    self.allocator.free(self.tasklists);
    self.topology.deinit();
    self.* = undefined;
}

pub fn getIndex(comptime T: type, items: []const T, name: []const u8) ?usize {
    for (0.., items) |i, item| {
        if (std.mem.eql(u8, item.collectionName(), name)) return i;
    }
    return null;
}

fn getByName(comptime T: type, items: []T, name: []const u8) ?*T {
    const index = getIndex(T, items, name) orelse return null;
    return &items[index];
}

pub fn getDirectory(self: *Self, name: []const u8) ?*Directory {
    return getByName(Directory, self.directories, name);
}

pub fn getJournal(self: *Self, name: []const u8) ?*Journal {
    return getByName(Journal, self.journals, name);
}

pub fn getTaskList(self: *Self, name: []const u8) ?*TaskList {
    return getByName(TaskList, self.tasklists, name);
}

pub fn getSelectedCollection(self: *Self, collection: CollectionType, name: []const u8) ?Collection {
    return switch (collection) {
        .Journal => .{
            .Journal = self.getJournal(name) orelse return null,
        },
        .Directory => .{
            .Directory = self.getDirectory(name) orelse return null,
        },
        .TaskList => .{
            .TaskList = self.getTaskList(name) orelse return null,
        },
        .DirectoryWithJournal => unreachable,
    };
}

pub fn getSelectedCollectionIndex(self: *Self, collection: CollectionType, name: []const u8) ?usize {
    return switch (collection) {
        .Directory => getIndex(Directory, self.directories, name),
        .Journal => getIndex(Journal, self.journals, name),
        .TaskList => getIndex(TaskList, self.tasklists, name),
        .DirectoryWithJournal => unreachable,
    };
}

pub fn getCollection(self: *Self, name: []const u8) ?Collection {
    const maybe_journal: ?*Journal = self.getJournal(name);
    const maybe_directory: ?*Directory = self.getDirectory(name);
    return Collection.initDirectoryJournal(maybe_directory, maybe_journal);
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
    const N_tasklists = self.tasklists.len;
    const N_directories = self.directories.len;
    const N_journals = self.journals.len;
    const N = N_directories + N_tasklists + N_journals;
    var cnames = try alloc.alloc(CollectionNameList.CollectionName, N);
    errdefer alloc.free(cnames);

    for (0.., self.directories) |i, c| {
        cnames[i] = .{
            .collection = .Directory,
            .name = c.collectionName(),
        };
    }

    for (N_directories.., self.journals) |i, c| {
        cnames[i] = .{
            .collection = .Journal,
            .name = c.collectionName(),
        };
    }

    for (N_directories + N_journals.., self.tasklists) |i, c| {
        cnames[i] = .{
            .collection = .TaskList,
            .name = c.collectionName(),
        };
    }

    return CollectionNameList.initOwned(alloc, cnames);
}

fn syncPtrs(infos: anytype, collections_list: anytype) void {
    for (infos, collections_list) |*info, *col| {
        col.container = info;
    }
}

pub fn newCollection(self: *Self, ctype: CollectionType, name: []const u8) !Collection {
    var topo_alloc = self.topology.mem.allocator();

    switch (ctype) {
        .DirectoryWithJournal => unreachable,
        .Directory => {
            const new_dir = try Topology.Directory.new(topo_alloc, "dir.", name);
            const s_ptr = try utils.push(
                Topology.Directory,
                topo_alloc,
                &self.topology.directories,
                new_dir,
            );
            var dir = try Directory.init(self.allocator, s_ptr, self.fs);
            errdefer dir.deinit();
            var dir_ptr = try utils.push(
                Directory,
                self.allocator,
                &self.directories,
                dir,
            );

            syncPtrs(self.topology.directories, self.directories);
            return .{ .Directory = dir_ptr };
        },
        .Journal => {
            const new = try Topology.Journal.new(topo_alloc, "journal.", name);
            const s_ptr = try utils.push(
                Topology.Journal,
                topo_alloc,
                &self.topology.journals,
                new,
            );
            var journal = try Journal.init(self.allocator, s_ptr, self.fs);
            errdefer journal.deinit();
            var journal_ptr = try utils.push(
                Journal,
                self.allocator,
                &self.journals,
                journal,
            );

            syncPtrs(self.topology.journals, self.journals);
            return .{ .Journal = journal_ptr };
        },
        else => unreachable, // todo
    }
}

pub fn removeCollection(self: *Self, ctype: CollectionType, index: usize) !bool {
    switch (ctype) {
        .Directory => {
            utils.moveToEnd(Directory, self.directories, index);
            var marked = self.directories[self.directories.len - 1];
            // remove associated filesystem
            self.fs.removeDir(marked.container.path);
            marked.deinit();

            self.directories[self.directories.len - 1].deinit();

            self.directories = try self.allocator.realloc(self.directories, self.directories.len - 1);

            utils.moveToEnd(Topology.Directory, self.topology.directories, index);
            self.topology.directories.len -= 1;

            syncPtrs(self.topology.directories, self.directories);
        },
        .Journal => {
            utils.moveToEnd(Journal, self.journals, index);
            self.journals[self.journals.len - 1].deinit();

            self.journals = try self.allocator.realloc(self.journals, self.journals.len - 1);

            utils.moveToEnd(Topology.Journal, self.topology.journals, index);
            self.topology.journals.len -= 1;

            syncPtrs(self.topology.journals, self.journals);
        },
        .TaskList => {
            utils.moveToEnd(TaskList, self.tasklists, index);
            self.tasklists[self.tasklists.len - 1].deinit();

            self.journals = try self.allocator.realloc(self.journals, self.journals.len - 1);

            utils.moveToEnd(Topology.TaskListDetails, self.topology.tasklists, index);
            self.topology.tasklists.len -= 1;

            syncPtrs(self.topology.tasklists, self.tasklists);
        },
        else => unreachable, // todo
    }
    return true;
}
