const std = @import("std");
pub const Directory = @import("Directory.zig");
pub const Journal = @import("Journal.zig");
pub const Tasklist = @import("Tasklist.zig");

const chains = @import("chains.zig");
const tags = @import("tags.zig");
pub const Tag = tags.Tag;
const types = @import("types.zig");
pub const Time = types.Time;
pub const timeNow = types.timeNow;
const FileSystem = @import("../FileSystem.zig");

const Root = @This();

pub const Error = error{ DuplicateItem, NeedsFileSystem };

pub const SCHEMA_VERSION = std.SemanticVersion{
    .major = 0,
    .minor = 3,
    .patch = 0,
};

pub fn schemaVersion() []const u8 {
    return std.fmt.comptimePrint(
        "{d}.{d}.{d}",
        .{
            SCHEMA_VERSION.major,
            SCHEMA_VERSION.minor,
            SCHEMA_VERSION.patch,
        },
    );
}

pub const Descriptor = struct {
    name: []const u8,
    path: []const u8,
    created: Time,
    modified: Time,
};

pub const CollectionType = enum {
    CollectionJournal,
    CollectionDirectory,
    CollectionTasklist,

    fn toFieldName(comptime t: CollectionType) []const u8 {
        return switch (t) {
            .CollectionDirectory => "directories",
            .CollectionJournal => "journals",
            .CollectionTasklist => "tasklists",
        };
    }

    fn toType(comptime t: CollectionType) type {
        return switch (t) {
            .CollectionDirectory => Directory,
            .CollectionJournal => Journal,
            .CollectionTasklist => Tasklist,
        };
    }
};

const Info = struct {
    _schema_version: []const u8 = schemaVersion(),

    // configuration variables
    editor: []const []const u8 = &.{"vim"},
    pager: []const []const u8 = &.{"less"},

    default_tasklist: []const u8 = "todo",
    default_directory: []const u8 = "notes",
    default_journal: []const u8 = "diary",

    // path to where we store the chains file
    chainpath: []const u8 = "chains.json",
    tagpath: []const u8 = "tags.json",

    tasklists: []Descriptor,
    directories: []Descriptor,
    journals: []Descriptor,
};

fn CachedItem(comptime T: type) type {
    return struct {
        // used to track if we need to write this to file (again)
        modified: bool = false,
        item: T,
    };
}

fn NameMap(comptime T: type) type {
    return std.StringHashMap(CachedItem(T));
}

const Cache = struct {
    const TasklistMap = NameMap(Tasklist.Info);
    const DirectoryMap = NameMap(Directory.Info);
    const JournalMap = NameMap(Journal.Info);

    tasklists: TasklistMap,
    directories: DirectoryMap,
    journals: JournalMap,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .tasklists = TasklistMap.init(allocator),
            .directories = DirectoryMap.init(allocator),
            .journals = JournalMap.init(allocator),
        };
    }

    pub fn deinit(cache: *Cache) void {
        cache.tasklists.deinit();
        cache.directories.deinit();
        cache.journals.deinit();
        cache.* = undefined;
    }
};

info: Info,
cache: Cache,
allocator: std.mem.Allocator,
tag_descriptors: ?tags.DescriptorList = null,
chain_list: ?chains.ChainList = null,
fs: ?FileSystem = null,

pub fn new(alloc: std.mem.Allocator) !Root {
    var info: Info = .{
        .tasklists = &.{},
        .directories = &.{},
        .journals = &.{},
    };

    var cache = Cache.init(alloc);

    return .{
        .info = info,
        .cache = cache,
        .allocator = alloc,
    };
}

pub fn deinit(self: *Root) void {
    self.cache.deinit();
    self.allocator.free(self.info.tasklists);
    self.allocator.free(self.info.directories);
    self.allocator.free(self.info.journals);
    if (self.tag_descriptors) |*td| td.deinit();
    if (self.chain_list) |*cl| cl.deinit();
    self.* = undefined;
}

fn logNoFilesystem(_: *const Root) void {
    std.log.default.debug("Skipping file system operations", .{});
}

fn getFileSystem(self: *Root) ?*FileSystem {
    if (self.fs) |*fs| {
        return fs;
    } else {
        self.logNoFilesystem();
        return null;
    }
}

fn readTaglist(self: *Root, fs: *FileSystem) !void {
    const content = try fs.readFileAlloc(self.allocator, self.info.tagpath);
    defer self.allocator.free(content);
    self.tag_descriptors = try tags.readTagDescriptors(self.allocator, content);
}

fn getTagDescriptorList(self: *Root) !*tags.DescriptorList {
    if (self.tag_descriptors == null) {
        if (self.getFileSystem()) |fs| {
            try self.readTaglist(fs);
        } else {
            self.tag_descriptors = tags.DescriptorList{
                .allocator = self.allocator,
            };
        }
    }
    return &self.tag_descriptors.?;
}

fn readChainList(self: *Root, fs: *FileSystem) !void {
    const content = try fs.readFileAlloc(self.allocator, self.info.chainpath);
    defer self.allocator.free(content);
    self.chain_list = try chains.readChainList(self.allocator, content);
}

fn getChainList(self: *Root) !*chains.ChainList {
    if (self.chain_list == null) {
        if (self.getFileSystem()) |fs| {
            try self.readChainList(fs);
        } else {
            self.chain_list = chains.ChainList{
                .mem = std.heap.ArenaAllocator.init(self.allocator),
            };
        }
    }
    return &self.chain_list.?;
}

fn createFileStructure(
    self: *Root,
    fs: *FileSystem,
    descr: Descriptor,
    comptime t: CollectionType,
) !void {
    // make the directory where the new collection will live
    const dir_name = std.fs.path.dirname(descr.path).?;
    try fs.makeDirIfNotExists(dir_name);

    // get the type of the collection we have just added
    const T = t.toType();

    // serialize a new blank topology file
    const str = try T.defaultSerialize(self.allocator);
    defer self.allocator.free(str);
    try fs.overwrite(descr.path, str);
}

/// Return a list of `Tag.Descriptor` of the valid tags. If no filesystem is
/// given, returns an empty list.
pub fn getTags(self: *Root) ?[]const Tag.Descriptor {
    var list = try self.getTagDescriptorList();
    return list.tags;
}

/// Add a `Descriptor` of type `CollectionType`. If the `self.fs` is not
/// `null`, this will also initialize the file system structure needed by
/// the collection.
/// Will return a `DuplicateItem` error if a descriptor of the same
/// `CollectionType` and name already exists.
pub fn addDescriptor(self: *Root, descr: Descriptor, comptime t: CollectionType) !void {
    var list = std.ArrayList(Descriptor).fromOwnedSlice(
        self.allocator,
        @field(self.info, t.toFieldName()),
    );

    for (list.items) |d| {
        if (std.mem.eql(u8, d.name, descr.name)) {
            return Error.DuplicateItem;
        }
    }

    if (self.getFileSystem()) |fs| {
        try self.createFileStructure(fs, descr, t);
    }

    try list.append(descr);
    @field(self.info, t.toFieldName()) = try list.toOwnedSlice();
}

/// Get the `Descriptor` matching name `name` of type `CollectionType`. Returns
/// `null` if no match found.
pub fn getDescriptor(
    self: *Root,
    name: []const u8,
    comptime t: CollectionType,
) ?Descriptor {
    const descriptors = @field(self.info, t.toFieldName());
    for (descriptors) |descr| {
        if (std.mem.eql(u8, descr.name, name)) {
            return descr;
        }
    }
    return null;
}

test "add and get descriptors" {
    var alloc = std.testing.allocator;
    var root = try Root.new(alloc);
    defer root.deinit();

    const new_directory: Descriptor = .{
        .name = "test",
        .path = "dir.test",
        .created = 0,
        .modified = 1,
    };
    try root.addDescriptor(new_directory, .CollectionDirectory);

    const fetched = root.getDescriptor(
        new_directory.name,
        .CollectionDirectory,
    ).?;

    try std.testing.expectEqualDeep(new_directory, fetched);
}

/// Add a new `Tag`. Will raise a `DuplicateItem` error if a tag by the same
/// name already exists. Added tag is not copied, so must outlive the `Root`
/// context
pub fn addNewTag(self: *Root, tag: Tag.Descriptor) !void {
    var list = try self.getTagDescriptorList();
    try list.addTagDescriptor(tag);
}

/// Add a new `Chain`. Will raise a `DuplicateItem` error if a chain by the
/// same name or alias already exists. Added chain is not copied, so must
/// outlive the `Root` context
pub fn addNewChain(self: *Root, chain: chains.Chain) !void {
    var list = try self.getChainList();
    try list.addChain(chain);
}

/// Serialize into a string for writing to file.  Caller owns the memory.
pub fn serialize(self: *const Root, allocator: std.mem.Allocator) ![]const u8 {
    return std.json.stringifyAlloc(
        allocator,
        self.info,
        .{ .whitespace = .indent_4 },
    );
}

test "serialize" {
    var alloc = std.testing.allocator;
    var root = try Root.new(alloc);
    defer root.deinit();

    const str = try root.serialize(alloc);
    defer alloc.free(str);

    const expected =
        \\{
        \\    "_schema_version": "0.3.0",
        \\    "editor": [
        \\        "vim"
        \\    ],
        \\    "pager": [
        \\        "less"
        \\    ],
        \\    "default_tasklist": "todo",
        \\    "default_directory": "notes",
        \\    "default_journal": "diary",
        \\    "chainpath": "chains.json",
        \\    "tagpath": "tags.json",
        \\    "tasklists": [],
        \\    "directories": [],
        \\    "journals": []
        \\}
    ;
    try std.testing.expectEqualStrings(str, expected);

    const new_directory: Descriptor = .{
        .name = "test",
        .path = "dir.test",
        .created = 0,
        .modified = 1,
    };
    try root.addDescriptor(new_directory, .CollectionDirectory);

    const str_with_dir = try root.serialize(alloc);
    defer alloc.free(str_with_dir);

    const expected_with_dir =
        \\{
        \\    "_schema_version": "0.3.0",
        \\    "editor": [
        \\        "vim"
        \\    ],
        \\    "pager": [
        \\        "less"
        \\    ],
        \\    "default_tasklist": "todo",
        \\    "default_directory": "notes",
        \\    "default_journal": "diary",
        \\    "chainpath": "chains.json",
        \\    "tagpath": "tags.json",
        \\    "tasklists": [],
        \\    "directories": [
        \\        {
        \\            "name": "test",
        \\            "path": "dir.test",
        \\            "created": 0,
        \\            "modified": 1
        \\        }
        \\    ],
        \\    "journals": []
        \\}
    ;
    try std.testing.expectEqualStrings(str_with_dir, expected_with_dir);
}

/// Add a new `Journal` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewJournal(self: *Root, descr: Descriptor) !Journal {
    try self.addDescriptor(descr, .CollectionJournal);
    try self.cache.journals.put(
        descr.name,
        .{ .item = .{}, .modified = true },
    );
    return self.lookupJournal(descr);
}

fn lookupJournal(self: *Root, descr: Descriptor) Journal {
    return .{
        .info = &self.cache.journals.getPtr(descr.name).?.item,
        .fs = self.fs,
        .allocator = self.allocator,
    };
}

/// Add a new `Tasklist` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewTasklist(self: *Root, descr: Descriptor) !Tasklist {
    try self.addDescriptor(descr, .CollectionTasklist);
    try self.cache.tasklists.put(
        descr.name,
        .{ .item = .{}, .modified = true },
    );
    return self.lookupTasklist(descr);
}

fn lookupTasklist(self: *Root, descr: Descriptor) Tasklist {
    return .{
        .info = &self.cache.tasklists.getPtr(descr.name).?.item,
        .allocator = self.allocator,
    };
}

/// Add a new `Directory` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewDirectory(self: *Root, descr: Descriptor) !Directory {
    try self.addDescriptor(descr, .CollectionDirectory);
    try self.cache.directories.put(
        descr.name,
        .{ .item = .{}, .modified = true },
    );
    return self.lookupDirectory(descr);
}

fn lookupDirectory(self: *Root, descr: Descriptor) Directory {
    return .{
        .info = &self.cache.directories.getPtr(descr.name).?.item,
        .fs = self.fs,
        .allocator = self.allocator,
    };
}

pub const ROOT_FILEPATH = "topology.json";

/// Create the file system. Overwrites any existing files, only to be used for
/// initalization or migration, else risks deleting existing data if not all read.
pub fn createFilesystem(self: *Root) !void {
    var fs = self.getFileSystem() orelse return Error.NeedsFileSystem;

    // migration: first we validate that all of the journals / directories /
    // tasklists we are holding onto actually have directories, and that
    // all the notes that we are tracking actually exist

    // TODO: exactly that

    {
        // create the main topology file
        const own_content = try self.serialize(self.allocator);
        defer self.allocator.free(own_content);
        try fs.overwrite(ROOT_FILEPATH, own_content);
    }

    {
        // create the tags file
        var list = try self.getTagDescriptorList();
        const tag_content = try list.serialize(self.allocator);
        defer self.allocator.free(tag_content);
        try fs.overwrite(self.info.tagpath, tag_content);
    }

    {
        // create the chain file
        var list = try self.getChainList();
        const chain_content = try list.serialize(self.allocator);
        defer self.allocator.free(chain_content);
        try fs.overwrite(self.info.chainpath, chain_content);
    }

    // journals
    try self.writeDescriptors(lookupJournal, fs, self.info.journals);
    try self.writeDescriptors(lookupDirectory, fs, self.info.directories);
    try self.writeDescriptors(lookupTasklist, fs, self.info.tasklists);
}

fn writeDescriptors(
    self: *Root,
    comptime lookup_fn: anytype,
    fs: *FileSystem,
    descrs: []const Descriptor,
) !void {
    for (descrs) |descr| {
        var item = lookup_fn(self, descr);
        // make the directory
        const dir_name = std.fs.path.dirname(descr.path).?;
        try fs.makeDirIfNotExists(dir_name);
        // write the contents
        const content = try item.serialize(self.allocator);
        defer self.allocator.free(content);
        try fs.overwrite(descr.path, content);
    }
}
