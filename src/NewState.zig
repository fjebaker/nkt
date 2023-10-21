const std = @import("std");
const utils = @import("utils.zig");

const Topology = @import("Topology.zig");
const ContentMap = @import("ContentMap.zig");
const FileSystem = @import("FileSystem.zig");

const Self = @This();

pub const Ordering = enum { Modified, Created };

pub const NotesDirectory = struct {
    const Note = Topology.Note;

    pub const NoteList = struct {
        allocator: std.mem.Allocator,
        items: []Note,

        pub usingnamespace utils.ListMixin(NoteList, Note);

        pub fn sortBy(self: *NoteList, ordering: Ordering) void {
            const sorter = std.sort.insertion;
            switch (ordering) {
                .Created => sorter(Note, self.items, {}, Note.sortCreated),
                .Modified => sorter(Note, self.items, {}, Note.sortModified),
            }
        }
    };

    directory: *Topology.Directory,
    content: ContentMap,
    directory_allocator: std.mem.Allocator,
    fs: FileSystem,

    /// Caller owns the memory
    pub fn getNoteList(
        self: *NotesDirectory,
        alloc: std.mem.Allocator,
    ) !NoteList {
        var notes = try alloc.alloc(Note, self.directory.infos.len);
        errdefer alloc.free(notes);

        for (notes, self.directory.infos) |*note, *info| {
            note.* = .{
                .info = info,
                .content = self.content.get(info.name),
            };
        }

        return NoteList.initOwned(alloc, notes);
    }

    pub fn readNoteContent(self: *NotesDirectory, note: *Note) !void {
        if (note.content == null) {
            note.content = try self.readContent(note.info.*);
        }
    }

    /// Reads note. Will return null if note does not exist. Does not
    /// attempt to read the note content. Use `readNote` to attempt to
    /// read content
    pub fn getNote(self: *NotesDirectory, name: []const u8) ?Note {
        for (self.directory.infos) |*info| {
            if (std.mem.eql(u8, info.name, name)) {
                return .{
                    .info = info,
                    .content = self.content.get(name),
                };
            }
        }
        return null;
    }

    fn readContent(self: *NotesDirectory, info: Note.Info) ![]const u8 {
        var alloc = self.content.mem.allocator();
        const content = try self.fs.readFileAlloc(alloc, info.path);
        self.content.putMove(info.name, content);
        return content;
    }

    pub fn readNote(self: *NotesDirectory, name: []const u8) !?Note {
        var note = self.getNote(name) orelse return null;
        note.content = self.readContent(note.info.*);
        return note;
    }

    pub fn addNote(
        self: *NotesDirectory,
        info: Note.Info,
        content: ?[]const u8,
    ) !void {
        utils.push(Note.Info, self.directory_allocator, self.directory.infos, info);
        if (content) |c| {
            try self.content.put(info.name, c);
        }
    }
};

pub const TrackedJournal = struct {
    const Journal = Topology.Journal;

    pub const DatedEntryList = struct {
        const Entry = Journal.Entry;

        pub const DatedEntry = struct {
            created: u64,
            modified: u64,
            entry: *Entry,

            pub fn sortCreated(_: void, lhs: DatedEntry, rhs: DatedEntry) bool {
                return lhs.created < rhs.created;
            }

            pub fn sortModified(_: void, lhs: DatedEntry, rhs: DatedEntry) bool {
                return lhs.modified < rhs.modified;
            }
        };

        allocator: std.mem.Allocator,
        items: []DatedEntry,
        _entries: []Entry,

        pub usingnamespace utils.ListMixin(DatedEntryList, DatedEntry);

        pub fn _deinit(self: *DatedEntryList) void {
            self.allocator.free(self._entries);
            self.allocator.free(self.items);
            self.* = undefined;
        }

        fn initOwnedEntries(alloc: std.mem.Allocator, entries: []Entry) !DatedEntryList {
            var items = try alloc.alloc(DatedEntry, entries.len);

            for (items, entries) |*item, *entry| {
                const created = entry.timeCreated();
                const modified = entry.lastModified();
                item.* = .{
                    .created = created,
                    .modified = modified,
                    .entry = entry,
                };
            }

            return .{
                .allocator = alloc,
                .items = items,
                ._entries = entries,
            };
        }

        pub fn sortBy(self: *DatedEntryList, ordering: Ordering) void {
            const sorter = std.sort.insertion;
            switch (ordering) {
                .Created => sorter(
                    DatedEntry,
                    self.items,
                    {},
                    DatedEntry.sortCreated,
                ),
                .Modified => sorter(
                    DatedEntry,
                    self.items,
                    {},
                    DatedEntry.sortModified,
                ),
            }
        }
    };

    journal_allocator: std.mem.Allocator,
    journal: *Journal,

    pub fn getDatedEntryList(
        self: *const TrackedJournal,
        alloc: std.mem.Allocator,
    ) !DatedEntryList {
        var entries = try alloc.dupe(Journal.Entry, self.journal.entries);
        errdefer alloc.free(entries);
        return DatedEntryList.initOwnedEntries(alloc, entries);
    }
};

pub const CollectionTypes = enum { Directory, Journal, DirectoryWithJournal };

pub const Collection = union(CollectionTypes) {
    pub const Errors = error{NoSuchCollection};
    Directory: *NotesDirectory,
    Journal: TrackedJournal,
    DirectoryWithJournal: struct {
        journal: TrackedJournal,
        directory: *NotesDirectory,
    },

    pub fn init(maybe_directory: ?*NotesDirectory, maybe_journal: ?TrackedJournal) ?Collection {
        if (maybe_directory != null and maybe_journal != null) {
            return .{
                .DirectoryWithJournal = .{
                    .journal = maybe_journal.?,
                    .directory = maybe_directory.?,
                },
            };
        } else if (maybe_journal) |journal| {
            return .{ .Journal = journal };
        } else if (maybe_directory) |dir| {
            return .{ .Directory = dir };
        }
        return null;
    }
};

pub const Config = struct {
    root_path: []const u8,
};

topology: Topology,
directories: []NotesDirectory,
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

    var directory_list = try std.ArrayList(NotesDirectory).initCapacity(
        alloc,
        topology.directories.len,
    );
    errdefer directory_list.deinit();
    errdefer for (directory_list.items) |*f| f.content.deinit();

    var topo_allocator = topology.mem.allocator();
    for (topology.directories) |*directory| {
        const f = NotesDirectory{
            .content = try ContentMap.init(alloc),
            .directory = directory,
            .directory_allocator = topo_allocator,
            .fs = fs,
        };
        try directory_list.append(f);
    }

    return .{
        .topology = topology,
        .directories = try directory_list.toOwnedSlice(),
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
    for (self.directories) |*f| f.content.deinit();
    self.allocator.free(self.directories);
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

pub fn getCollection(self: *Self, name: []const u8) !Collection {
    var maybe_journal: ?TrackedJournal = null;
    var maybe_directory: ?*NotesDirectory = null;

    for (self.topology.journals) |*journal| {
        if (std.mem.eql(u8, journal.name, name))
            maybe_journal = .{
                .journal_allocator = self.topology.mem.allocator(),
                .journal = journal,
            };
    }

    for (self.directories) |*directory| {
        if (std.mem.eql(u8, directory.directory.name, name))
            maybe_directory = directory;
    }

    return Collection.init(maybe_directory, maybe_journal) orelse
        Collection.Errors.NoSuchCollection;
}

pub const CollectionNameList = struct {
    pub const CollectionName = struct {
        collection: CollectionTypes,
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

    for (N_directories.., self.topology.journals) |i, j| {
        cnames[i] = .{
            .collection = .Journal,
            .name = j.name,
        };
    }

    return CollectionNameList.initOwned(alloc, cnames);
}
