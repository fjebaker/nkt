const std = @import("std");
const FileSystem = @import("../FileSystem.zig");
const Root = @import("../topology/Root.zig");
const Tasklist = @import("../topology/Tasklist.zig");

pub const Error = error{UnknownVersion};

/// Migrate path and over-ride `root_dir`
pub fn migratePath(allocator: std.mem.Allocator, root_dir: []const u8) !void {
    var old = try FileSystem.init(root_dir);
    defer old.deinit();

    try migrateFileSystem(allocator, &old);
}

const SchemaReader = struct {
    _schema_version: []const u8,

    pub fn toSemanticVersion(self: *SchemaReader) !std.SemanticVersion {
        return try std.SemanticVersion.parse(self._schema_version);
    }
};

fn migrateFileSystem(allocator: std.mem.Allocator, old: *FileSystem) !void {
    var mem = std.heap.ArenaAllocator.init(allocator);
    defer mem.deinit();
    var alloc = mem.allocator();

    const data = try old.readFileAlloc(alloc, "topology.json");
    // learn what schema version we are migrating from
    var parsed = try std.json.parseFromSliceLeaky(
        SchemaReader,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    );

    const version = try parsed.toSemanticVersion();

    // init with non-arena allocator so that it is not freed at the end
    var new = Root.new(alloc);

    if (version.major == 0 and version.minor == 2 and version.patch == 0) {
        try migrate_0_2_0(alloc, old, &new, data);
    } else {
        return Error.UnknownVersion;
    }

    new.fs = old.*;
    // new file system
    try new.createFilesystem();
    try new.writeChanges();
}

const Topology_0_2_0 = @import("Topology_0_2_0.zig");
fn migrate_0_2_0(
    allocator: std.mem.Allocator,
    fs: *FileSystem,
    new: *Root,
    topology_data: []const u8,
) !void {
    const topo = try Topology_0_2_0.init(allocator, topology_data);

    // trivial ones
    new.info.editor = topo.editor;
    new.info.pager = topo.pager;
    new.info.chainpath = topo.chainpath;

    // migrate the tags
    for (topo.tags) |t| {
        try new.addNewTag(
            .{ .name = t.name, .created = t.created, .color = t.color },
        );
    }

    // migrate the chains
    const chain_content = try fs.readFileAlloc(allocator, topo.chainpath);
    const chains = try Topology_0_2_0.parseChains(allocator, chain_content);
    for (chains) |chain| {
        try new.addNewChain(.{
            .name = chain.name,
            .alias = chain.alias,
            .details = chain.details,
            .active = chain.active,
            .created = chain.created,
            .completed = chain.completed,
            .tags = try convertTags_0_2_0(allocator, chain.tags),
        });
    }

    // migrate the taskslists
    for (topo.tasklists) |tl| {
        var tasklist = try new.addNewTasklist(
            .{
                .name = tl.name,
                .path = tl.path,
                .created = tl.created,
                .modified = tl.modified,
            },
        );

        tasklist.info.tags = try convertTags_0_2_0(allocator, tl.tags);

        // migrate the tasks in the tasklist
        const content = try fs.readFileAlloc(allocator, tl.path);
        const tasks = try Topology_0_2_0.parseTasks(allocator, content);
        for (tasks) |t| {
            try tasklist.addNewTask(.{
                .outcome = t.title,
                .details = t.details,
                .created = t.created,
                .modified = t.modified,
                .hash = Tasklist.hash(.{
                    .action = null,
                    .outcome = t.title,
                }),
                .due = t.due,
                .done = t.completed,
                .archived = t.archived,
                .importance = convertImportance_0_2_0(t.importance),
                .tags = try convertTags_0_2_0(allocator, t.tags),
            });
        }
    }

    // migrate the journals
    for (topo.journals) |jr| {
        const now = Root.timeNow();
        var journal = try new.addNewJournal(.{
            .name = jr.name,
            .path = try std.fs.path.join(
                allocator,
                &.{ jr.path, Root.Journal.TOPOLOGY_FILENAME },
            ),
            .created = now,
            .modified = now,
        });

        journal.info.tags = try convertTags_0_2_0(allocator, jr.tags);

        for (jr.infos) |day| {
            try journal.addNewDay(.{
                .name = day.name,
                .path = day.path,
                .created = day.created,
                .modified = day.modified,
                .tags = try convertTags_0_2_0(allocator, day.tags),
            });
            // todo: don't really want to read all of the entries into memory
            // so we'll make a number of filesystem calls here to do the
            // conversion
            const content = try fs.readFileAlloc(allocator, day.path);
            const entries = try Topology_0_2_0.parseEntries(allocator, content);
            for (entries) |entry| {
                try journal.addNewEntryToPath(day.path, .{
                    .text = entry.item,
                    .created = entry.created,
                    .modified = entry.modified,
                    .tags = try convertTags_0_2_0(allocator, entry.tags),
                });
            }
        }

        journal.fs = fs.*;
        try journal.writeDays();
    }

    // migrate directories
    for (topo.directories) |dir| {
        const now = Root.timeNow();
        var directory = try new.addNewDirectory(.{
            .name = dir.name,
            .path = try std.fs.path.join(
                allocator,
                &.{ dir.path, Root.Directory.TOPOLOGY_FILENAME },
            ),
            .created = now,
            .modified = now,
        });

        directory.info.tags = try convertTags_0_2_0(allocator, dir.tags);

        for (dir.infos) |note| {
            try directory.addNewNote(.{
                .name = note.name,
                .path = note.path,
                .created = note.created,
                .modified = note.modified,
                .tags = try convertTags_0_2_0(allocator, note.tags),
            });
        }
    }

    // now that everything has been migrated, we remove the old files

}

fn convertTags_0_2_0(
    allocator: std.mem.Allocator,
    tags: []const Topology_0_2_0.Tag,
) ![]Root.Tag {
    var list = std.ArrayList(Root.Tag).init(allocator);
    defer list.deinit();

    for (tags) |t| {
        try list.append(.{
            .name = t.name,
            .added = t.added,
        });
    }

    return try list.toOwnedSlice();
}

fn convertImportance_0_2_0(
    imp: Topology_0_2_0.Task.Importance,
) Root.Tasklist.Importance {
    return switch (imp) {
        .high => .High,
        .low => .Low,
        .urgent => .Urgent,
    };
}
