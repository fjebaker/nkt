const std = @import("std");
const utils = @import("utils.zig");

const collections = @import("collections.zig");

pub const CollectionType = collections.Type;
pub const Collection = collections.Collection;
pub const ItemType = collections.ItemType;
pub const Item = collections.Item;
pub const Ordering = collections.Ordering;
pub const MaybeCollection = collections.MaybeCollection;
pub const MaybeItem = collections.MaybeItem;

pub const Error = error{NoSuchCollection};

const Topology = @import("collections/Topology.zig");
const FileSystem = @import("FileSystem.zig");

const Self = @This();

pub const Config = struct {
    root_path: []const u8,
};

topology: Topology,
directories: []Collection,
journals: []Collection,
tasklists: []Collection,
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

fn makeCollection(
    alloc: std.mem.Allocator,
    comptime T: CollectionType,
    comptime K: type,
    items: []K,
    fs: FileSystem,
) ![]Collection {
    var list = try std.ArrayList(Collection).initCapacity(alloc, items.len);
    errdefer list.deinit();
    errdefer for (list.items) |*i| i.deinit();

    for (items) |*item| {
        var c = try Collection.init(alloc, T, item, fs);
        try list.append(c);
    }

    return try list.toOwnedSlice();
}

pub fn init(alloc: std.mem.Allocator, config: Config) !Self {
    var fs = try FileSystem.init(config.root_path);
    errdefer fs.deinit();

    var topology = try loadTopologyElseCreate(alloc, fs);
    errdefer topology.deinit();

    var dirs = try makeCollection(
        alloc,
        CollectionType.Directory,
        Topology.Description,
        topology.directories,
        fs,
    );
    errdefer alloc.free(dirs);
    errdefer for (dirs) |*d| d.deinit();

    var journals = try makeCollection(
        alloc,
        CollectionType.Journal,
        Topology.Journal,
        topology.journals,
        fs,
    );
    errdefer alloc.free(dirs);
    errdefer for (dirs) |*d| d.deinit();

    var tasklists = try makeCollection(
        alloc,
        CollectionType.Tasklist,
        Topology.TasklistInfo,
        topology.tasklists,
        fs,
    );
    errdefer alloc.free(dirs);
    errdefer for (dirs) |*d| d.deinit();

    return .{
        .topology = topology,
        .directories = dirs,
        .tasklists = tasklists,
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
    for (self.tasklists) |*tls| {
        try tls.writeChanges(self.allocator);
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

pub fn getIndex(comptime T: CollectionType, items: []const Collection, name: []const u8) ?usize {
    for (0.., items) |i, item| {
        if (item != T) continue;
        if (std.mem.eql(u8, item.getName(), name)) return i;
    }
    return null;
}

fn getByName(comptime T: CollectionType, items: []Collection, name: []const u8) ?*Collection {
    const index = getIndex(T, items, name) orelse return null;
    return &items[index];
}

pub fn getDirectory(self: *Self, name: []const u8) ?*Collection {
    return getByName(.Directory, self.directories, name);
}

pub fn getJournal(self: *Self, name: []const u8) ?*Collection {
    return getByName(.Journal, self.journals, name);
}

pub fn getTasklist(self: *Self, name: []const u8) ?*Collection {
    return getByName(.Tasklist, self.tasklists, name);
}

pub fn getSelectedCollection(self: *Self, collection: CollectionType, name: []const u8) ?*Collection {
    return switch (collection) {
        .Journal => self.getJournal(name),
        .Directory => self.getDirectory(name),
        .Tasklist => self.getTasklist(name),
    };
}

pub fn getSelectedCollectionIndex(self: *Self, collection: CollectionType, name: []const u8) ?usize {
    return switch (collection) {
        .Directory => getIndex(.Directory, self.directories, name),
        .Journal => getIndex(.Journal, self.journals, name),
        .Tasklist => getIndex(.Tasklist, self.tasklists, name),
    };
}

pub fn getCollectionByName(self: *Self, name: []const u8) ?MaybeCollection {
    const maybe_journal: ?*Collection = self.getJournal(name);
    const maybe_directory: ?*Collection = self.getDirectory(name);
    const maybe_tasklist: ?*Collection = self.getTasklist(name);

    if (maybe_directory == null and maybe_journal == null and maybe_tasklist == null) return null;
    return MaybeCollection{
        .journal = maybe_journal,
        .directory = maybe_directory,
        .tasklist = maybe_tasklist,
    };
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
            .name = c.getName(),
        };
    }

    for (N_directories.., self.journals) |i, c| {
        cnames[i] = .{
            .collection = .Journal,
            .name = c.getName(),
        };
    }

    for (N_directories + N_journals.., self.tasklists) |i, c| {
        cnames[i] = .{
            .collection = .Tasklist,
            .name = c.getName(),
        };
    }

    return CollectionNameList.initOwned(alloc, cnames);
}

fn syncPtrs(descriptions: []Topology.Description, collections_list: anytype) void {
    for (descriptions, collections_list) |*descr, *col| {
        switch (col.*) {
            .Tasklist => unreachable,
            inline else => |*c| c.description = descr,
        }
    }
}

pub fn newCollection(self: *Self, ctype: CollectionType, name: []const u8) !*Collection {
    var topo_alloc = self.topology.mem.allocator();

    switch (ctype) {
        .Directory => {
            const new_dir = try Topology.Directory.new(topo_alloc, "dir.", name);
            const s_ptr = try utils.push(
                Topology.Directory,
                topo_alloc,
                &self.topology.directories,
                new_dir,
            );
            var dir = try Collection.init(self.allocator, .Directory, s_ptr, self.fs);
            errdefer dir.deinit();
            var dir_ptr = try utils.push(
                Collection,
                self.allocator,
                &self.directories,
                dir,
            );

            syncPtrs(self.topology.directories, self.directories);
            return dir_ptr;
        },
        .Journal => {
            const new = try Topology.Journal.new(topo_alloc, "journal.", name);
            const s_ptr = try utils.push(
                Topology.Journal,
                topo_alloc,
                &self.topology.journals,
                new,
            );
            var journal = try Collection.init(self.allocator, .Journal, s_ptr, self.fs);
            errdefer journal.deinit();
            var journal_ptr = try utils.push(
                Collection,
                self.allocator,
                &self.journals,
                journal,
            );

            syncPtrs(self.topology.journals, self.journals);
            return journal_ptr;
        },
        else => unreachable, // todo
    }
}

inline fn removeCollectionNamed(self: *Self, comptime field_name: []const u8, index: usize) !void {
    const T = comptime if (std.mem.eql(u8, field_name, "directories"))
        Topology.Directory
    else if (std.mem.eql(u8, field_name, "journals"))
        Topology.Journal
    else if (std.mem.eql(u8, field_name, "tasklists"))
        Topology.TasklistInfo
    else
        @compileError("unknown field");

    var items = @field(self, field_name);
    utils.moveToEnd(Collection, items, index);
    var marked = items[items.len - 1];

    try self.fs.dir.deleteDir(marked.getPath());

    marked.deinit();
    @field(self, field_name) = try self.allocator.realloc(items, items.len - 1);

    utils.moveToEnd(T, @field(self.topology, field_name), index);
    @field(self.topology, field_name).len -= 1;

    syncPtrs(@field(self.topology, field_name), @field(self, field_name));
}

pub fn removeCollection(self: *Self, ctype: CollectionType, index: usize) !void {
    switch (ctype) {
        .Directory => {
            try removeCollectionNamed(self, "directories", index);
        },
        .Journal => {
            try removeCollectionNamed(self, "journals", index);
        },
        .Tasklist => unreachable,
    }
}
