const std = @import("std");
pub const Directory = @import("Directory.zig");
pub const Journal = @import("Journal.zig");
pub const Tasklist = @import("Tasklist.zig");

const chains = @import("chains.zig");
const tags = @import("tags.zig");
pub const Tag = tags.Tag;
const time = @import("time.zig");
pub const Time = time.Time;
pub const timeNow = time.timeNow;
const FileSystem = @import("../FileSystem.zig");

const Root = @This();

/// The filename of the root topology file
pub const ROOT_FILEPATH = "topology.json";

pub const Error = error{
    DuplicateItem,
    NeedsFileSystem,
    InvalidExtension,
};

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

/// Struct representing the different methods for compiling and exporting
/// notes.
pub const TextCompiler = struct {
    /// Name for internal use
    name: []const u8,
    /// Command used to compile / export the text
    command: ?[]const []const u8 = null,
    /// File extensions that it is applicable for
    extensions: []const []const u8,
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

    fn getTopologyName(comptime t: CollectionType) []const u8 {
        return switch (t) {
            .CollectionDirectory => Directory.TOPOLOGY_FILENAME,
            .CollectionJournal => Journal.TOPOLOGY_FILENAME,
            .CollectionTasklist => Tasklist.TOPOLOGY_FILENAME,
        };
    }

    fn ToType(comptime t: CollectionType) type {
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

    // different text compilers
    text_compilers: []const TextCompiler = &.{
        // include the default markdown compiler
        .{ .name = "markdown", .extensions = &.{".md"} },
    },

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
// allocator for when things need to have the same lifetime as the root
arena: std.heap.ArenaAllocator,
tag_descriptors: ?tags.DescriptorList = null,
chain_list: ?chains.ChainList = null,
fs: ?FileSystem = null,

/// Initialize a new `Root` with all default values
pub fn new(alloc: std.mem.Allocator) Root {
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
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
}

/// Load the `Root` information from the topology file in the home directory.
pub fn load(self: *Root) !void {
    var fs = self.getFileSystem() orelse
        return Error.NeedsFileSystem;

    const contents = try fs.readFileAlloc(self.allocator, ROOT_FILEPATH);
    defer self.allocator.free(contents);

    try self.loadFromString(contents);
}

/// Load the `Root.Info` from a JSON string. Will make copies of all strings,
/// so the input string may be freed later.
pub fn loadFromString(self: *Root, string: []const u8) !void {
    var alloc = self.arena.allocator();
    self.info = try std.json.parseFromSliceLeaky(
        Info,
        alloc,
        string,
        .{ .allocate = .alloc_always },
    );
}

pub fn deinit(self: *Root) void {
    self.cache.deinit();
    self.allocator.free(self.info.tasklists);
    self.allocator.free(self.info.directories);
    self.allocator.free(self.info.journals);
    if (self.tag_descriptors) |*td| td.deinit();
    if (self.chain_list) |*cl| cl.deinit();
    self.arena.deinit();
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
    const T = t.ToType();

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
    var root = Root.new(alloc);
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
    var root = Root.new(alloc);
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
        \\    "text_compilers": [
        \\        {
        \\            "name": "markdown",
        \\            "command": null,
        \\            "extensions": [
        \\                ".md"
        \\            ]
        \\        }
        \\    ],
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
        \\    "text_compilers": [
        \\        {
        \\            "name": "markdown",
        \\            "command": null,
        \\            "extensions": [
        \\                ".md"
        \\            ]
        \\        }
        \\    ],
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

fn getPathPrefix(t: CollectionType) []const u8 {
    return switch (t) {
        .CollectionDirectory => Directory.PATH_PREFIX,
        .CollectionJournal => Journal.PATH_PREFIX,
        .CollectionTasklist => unreachable,
    };
}

// TODO: verify the extension is actually a valid one / we have a text compiler
// for it
fn getExtension(_: *const Root, comptime t: CollectionType, opts: NewCollectionOptions) error{InvalidExtension}![]const u8 {
    const ext = switch (t) {
        .CollectionDirectory => opts.extension orelse "md",
        .CollectionTasklist, .CollectionJournal => "json",
    };

    // trim the period
    if (ext[0] == '.') {
        return ext[1..];
    } else {
        return ext;
    }
}

fn newPathFrom(
    self: *Root,
    name: []const u8,
    comptime t: CollectionType,
) ![]const u8 {
    var alloc = self.arena.allocator();
    const base_dir = switch (t) {
        .CollectionDirectory => try std.mem.join(
            alloc,
            ".",
            &.{ Directory.PATH_PREFIX, name },
        ),
        .CollectionJournal => try std.mem.join(
            alloc,
            ".",
            &.{ Journal.PATH_PREFIX, name },
        ),
        .CollectionTasklist => Tasklist.TASKLIST_DIRECTORY,
    };

    return try std.fs.path.join(
        alloc,
        &.{ base_dir, t.getTopologyName() },
    );
}

const NewCollectionOptions = struct {
    extension: ?[]const u8 = null,
};

/// Add a new collection of type `CollectionType`. Returns the corresponding
/// collection instance.
pub fn addNewCollection(
    self: *Root,
    name: []const u8,
    comptime t: CollectionType,
) !t.ToType() {
    const now = time.timeNow();
    const descr: Descriptor = .{
        .name = name,
        .created = now,
        .modified = now,
        .path = try self.newPathFrom(name, t),
    };

    return switch (t) {
        .CollectionDirectory => self.addNewDirectory(descr),
        .CollectionJournal => self.addNewJournal(descr),
        .CollectionTasklist => self.addNewTasklist(descr),
    };
}

fn lookupCollection(
    self: *Root,
    descr: Descriptor,
    comptime t: CollectionType,
) t.ToType() {
    const info_ptr = &@field(self.cache, t.toFieldName()).getPtr(descr.name).?.item;
    return switch (t) {
        .CollectionJournal => .{
            .info = info_ptr,
            .fs = self.fs,
            .allocator = self.allocator,
        },
        .CollectionDirectory => .{
            .info = info_ptr,
            .fs = self.fs,
            .allocator = self.allocator,
        },
        .CollectionTasklist => .{
            .info = info_ptr,
            .allocator = self.allocator,
        },
    };
}

fn addNewCollectionFromDescription(
    self: *Root,
    descr: Descriptor,
    comptime t: CollectionType,
) !t.ToType() {
    try self.addDescriptor(descr, t);
    try @field(self.cache, t.toFieldName()).put(
        descr.name,
        .{ .item = .{}, .modified = true },
    );
    return self.lookupCollection(descr, t);
}

/// Add a new `Tasklist` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewTasklist(self: *Root, descr: Descriptor) !Tasklist {
    return try self.addNewCollectionFromDescription(descr, .CollectionTasklist);
}

/// Add a new `Directory` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewDirectory(self: *Root, descr: Descriptor) !Directory {
    return try self.addNewCollectionFromDescription(descr, .CollectionDirectory);
}

/// Add a new `Journal` to the index, and return a pointer into the cache to
/// allow modification.
pub fn addNewJournal(self: *Root, descr: Descriptor) !Journal {
    return try self.addNewCollectionFromDescription(descr, .CollectionJournal);
}

/// Get a desired collection by name and `CollectionType`. Returns the
/// associated collection type, or null if no such collection can be found.
/// Will read any associated topology files from disk if needed.
pub fn getCollection(
    self: *Root,
    name: []const u8,
    comptime t: CollectionType,
) !?t.ToType() {
    var fs = self.getFileSystem() orelse
        return Error.NeedsFileSystem;

    const descr = self.getDescriptor(name, t) orelse return null;
    const info_content = try fs.readFileAlloc(self.allocator, descr.path);
    defer self.allocator.free(info_content);

    const InfoType = t.ToType().Info;
    var alloc = self.arena.allocator();

    var info = std.json.parseFromSliceLeaky(
        alloc,
        InfoType,
        info_content,
        .{ .allocate = .alloc_always },
    );

    // create the stash
    @field(self.cache, t.toFieldName()).put(
        descr.name,
        .{ .item = info, .modified = true },
    );

    try self.lookupCollection(descr, t);
}

/// Get a `Journal` by name. Returns `null` if name is invalid.
pub fn getJournal(self: *Root, name: []const u8) !?Journal {
    return self.getCollection(name, .CollectionJournal);
}

/// Add all of the default collections to the root
pub fn addInitialCollections(self: *Root) !void {
    _ = try self.addNewCollection(
        self.info.default_directory,
        .CollectionDirectory,
    );
    // the journal has an accompanying notes directory
    _ = try self.addNewCollection(
        self.info.default_journal,
        .CollectionJournal,
    );
    _ = try self.addNewCollection(
        self.info.default_journal,
        .CollectionDirectory,
    );
    _ = try self.addNewCollection(
        self.info.default_tasklist,
        .CollectionTasklist,
    );

    // initialize an empty tag descriptor list
    self.tag_descriptors = tags.DescriptorList{
        .allocator = self.allocator,
    };

    // initialize an empty chain list
    self.chain_list = chains.ChainList{
        .mem = std.heap.ArenaAllocator.init(self.allocator),
    };
}

/// Create the file system. Overwrites any existing files, only to be used for
/// initalization or migration, else risks deleting existing data if not all
/// read.
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
    try self.writeDescriptors(fs, .CollectionJournal);
    try self.writeDescriptors(fs, .CollectionDirectory);
    try self.writeDescriptors(fs, .CollectionTasklist);
}

fn writeDescriptors(
    self: *Root,
    fs: *FileSystem,
    comptime t: CollectionType,
) !void {
    const descrs = @field(self.info, t.toFieldName());
    for (descrs) |descr| {
        var item = self.lookupCollection(descr, t);
        // make the directory
        const dir_name = std.fs.path.dirname(descr.path).?;
        try fs.makeDirIfNotExists(dir_name);
        // write the contents
        const content = try item.serialize(self.allocator);
        defer self.allocator.free(content);
        try fs.overwrite(descr.path, content);
    }
}
