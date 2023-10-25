const std = @import("std");
const utils = @import("../utils.zig");

const content_map = @import("content_map.zig");

const indexing = @import("indexing.zig");
const IndexContainer = indexing.IndexContainer;

const Topology = @import("Topology.zig");
const FileSystem = @import("../FileSystem.zig");

pub fn CollectionTemplate(
    comptime Container: type,
) type {
    return struct {
        const Self = @This();
        const ChildType = Container.Child;
        const TrackedChildType = Container.TrackedChild(Self);
        const ContentMap = Container.ContentMap;
        pub const Child = ChildType;
        pub const TrackedChild = TrackedChildType;

        mem: std.heap.ArenaAllocator,
        container: *Topology.CollectionScheme,
        content: ContentMap,
        fs: FileSystem,
        index: IndexContainer,

        pub fn init(alloc: std.mem.Allocator, c: *Topology.CollectionScheme, fs: FileSystem) !Self {
            var mem = std.heap.ArenaAllocator.init(alloc);

            var content = try ContentMap.init(alloc);
            errdefer content.deinit();

            var index = try indexing.makeIndex(alloc, c.infos);
            errdefer index.deinit();

            return .{
                .mem = mem,
                .container = c,
                .content = content,
                .fs = fs,
                .index = index,
            };
        }

        pub fn deinit(self: *Self) void {
            self.content.deinit();
            self.index.deinit();
            self.mem.deinit();
            self.* = undefined;
        }

        pub const List = struct {
            allocator: std.mem.Allocator,
            items: []Child,

            pub usingnamespace utils.ListMixin(List, Child);

            pub fn sortBy(self: *List, ordering: Ordering) void {
                const sorter = std.sort.insertion;
                switch (ordering) {
                    .Created => sorter(Child, self.items, {}, Child.sortCreated),
                    .Modified => sorter(Child, self.items, {}, Child.sortModified),
                }
            }
        };

        pub fn getChildList(
            self: *const Self,
            alloc: std.mem.Allocator,
        ) !List {
            const items = self.container.infos;
            var children = try alloc.alloc(Child, items.len);
            errdefer alloc.free(children);

            for (children, items) |*child, *info| {
                child.* = Child.init(
                    info,
                    self.content.get(info.name),
                );
            }

            return List.initOwned(alloc, children);
        }

        pub fn getIndex(self: *Self, index: usize) ?Self.TrackedChild {
            const name = self.index.get(index) orelse
                return null;
            return self.get(name);
        }

        fn prepareChild(self: *Self, info: *Child.Info) Self.TrackedChild {
            var item: Child = .{ .children = self.content.get(info.name), .info = info };
            return .{ .collection = self, .item = item };
        }

        /// Get the child by name. Will not attempt to read the file with the
        /// child's content until `ensureContent` is called on the Child.
        pub fn get(self: *Self, name: []const u8) ?Self.TrackedChild {
            var items = self.container.infos;
            for (items) |*item| {
                if (std.mem.eql(u8, item.name, name)) {
                    return prepareChild(self, item);
                }
            }
            return null;
        }

        pub fn getByDate(
            self: *Self,
            date: utils.Date,
            order: Ordering,
        ) ?Self.TrackedChild {
            var items = self.container.infos;
            for (items) |*item| {
                const entry_date = utils.Date.initUnixMs(switch (order) {
                    .Created => item.timeCreated(),
                    .Modified => item.timeModified(),
                });
                if (utils.areSameDay(entry_date, date)) {
                    return prepareChild(self, item);
                }
            }
            return null;
        }

        pub fn getAndRead(self: *Self, name: []const u8) ?Self.TrackedChild {
            var tc = self.get(name) orelse return null;
            self.readChildContent(&tc.item);
            return tc;
        }

        pub fn readChildContent(self: *Self, entry: *Child) !void {
            if (entry.children == null) {
                var alloc = self.content.allocator();
                const name = entry.getName();

                const string = try self.fs.readFileAlloc(alloc, entry.getPath());
                const children = try Child.parseContent(alloc, string);
                try self.content.putMove(entry.getName(), children);

                entry.children = self.content.get(name);
            }
        }

        fn childPath(self: *Self, name: []const u8) ![]const u8 {
            const alloc = self.mem.allocator();
            const filename = try std.mem.concat(
                alloc,
                u8,
                &.{ name, Container.DEFAULT_FILE_EXTENSION },
            );
            return try std.fs.path.join(
                alloc,
                &.{ self.container.path, filename },
            );
        }

        pub fn newChild(
            self: *Self,
            name: []const u8,
        ) !Self.TrackedChild {
            var alloc = self.mem.allocator();
            const owned_name = try alloc.dupe(u8, name);

            const now = utils.now();
            const info: Child.Info = .{
                .modified = now,
                .created = now,
                .name = owned_name,
                .path = try childPath(self, owned_name),
                .tags = try utils.emptyTagList(alloc),
            };

            var item = try self.addChild(info, null);
            return .{ .collection = self, .item = item };
        }

        fn addChild(self: *Self, info: Child.Info, items: ?[]Child.Item) !Child {
            var alloc = self.mem.allocator();
            const info_ptr = try utils.push(
                Child.Info,
                alloc,
                &self.container.infos,
                info,
            );

            if (items) |i| {
                try self.content.put(info.name, i);
            }

            // write a template to the file
            try self.fs.overwrite(info.path, Child.contentTemplate(alloc, info));

            return .{
                .info = info_ptr,
                .children = self.content.get(info.name),
            };
        }

        pub fn remove(self: *Self, item: *Child.Info) !void {
            var items = &self.container.infos;
            const index = for (items.*, 0..) |i, j| {
                if (std.mem.eql(u8, i.name, item.name)) break j;
            } else unreachable; // todo: proper error
            // todo: better remove
            // this is okay since everything is arena allocator tracked?
            utils.moveToEnd(Child.Info, items.*, index);
            items.len -= 1;
        }

        fn addItem(self: *Self, entry: *Child, item: Child.Item) !void {
            var alloc = self.content.allocator();

            try self.readChildContent(entry);
            var children = entry.children.?;

            _ = try utils.push(Child.Item, alloc, &children, item);
            entry.children = children;
            try self.content.putMove(entry.getName(), entry.children.?);
        }

        pub fn collectionName(self: *const Self) []const u8 {
            return self.container.name;
        }
    };
}

const Directory = struct {
    pub const DEFAULT_FILE_EXTENSION = ".md";
    pub const Child = Topology.Note;
    pub const ContentMap = content_map.ContentMap([]const u8);
    pub fn TrackedChild(comptime Self: type) type {
        return struct {
            collection: *Self,
            item: Child,
            pub fn relativePath(self: @This()) []const u8 {
                return self.item.info.path;
            }

            pub fn add(
                self: *@This(),
                content: []const u8,
                fs: FileSystem,
            ) !void {
                var alloc = self.collection.content.allocator();
                const owned_text = try alloc.dupe(u8, content);

                try self.collection.addItem(&self.item, owned_text);
                // write to file
                try fs.overwrite(self.relativePath(), owned_text);
            }
        };
    }
};

const Journal = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const Child = Topology.Entry;
    pub const ContentMap = content_map.ContentMap([]Child.Item);
    pub const JournalError = error{DuplicateEntry};
    pub fn TrackedChild(comptime Self: type) type {
        return struct {
            collection: *Self,
            item: Child,

            pub fn relativePath(self: @This()) []const u8 {
                return self.item.info.path;
            }

            pub fn add(self: *@This(), text: []const u8) !void {
                var alloc = self.collection.content.allocator();
                const now = utils.now();
                const owned_text = try alloc.dupe(u8, text);

                const item: Child.Item = .{
                    .created = now,
                    .modified = now,
                    .item = owned_text,
                    .tags = try utils.emptyTagList(alloc),
                };

                try self.collection.addItem(&self.item, item);
            }

            pub fn remove(self: *@This(), item: Child.Item) !void {
                const index = for (self.item.children.?, 0..) |i, j| {
                    if (i.created == item.created) break j;
                } else unreachable; // todo
                utils.moveToEnd(Child.Item, self.item.children.?, index);
                self.item.children.?.len -= 1;
                try self.collection.content.putMove(
                    self.item.info.name,
                    self.item.children.?,
                );
            }
        };
    }
};

const TaskListDetails = struct {
    pub const DEFAULT_FILE_EXTENSION = ".json";
    pub const Child = Topology.TaskList;
    pub const ContentMap = content_map.ContentMap([]Child.Item);
    pub fn TrackedChild(comptime Self: type) type {
        return struct {
            collection: *Self,
            item: Child,

            pub fn relativePath(self: @This()) []const u8 {
                return self.item.info.path;
            }

            pub const TaskOptions = struct {
                due: ?u64 = null,
                importance: Child.Item.Importance = .low,
                details: []const u8 = "",
            };

            pub fn add(
                self: *@This(),
                text: []const u8,
                options: TaskOptions,
            ) !void {
                var alloc = self.collection.content.allocator();
                const now = utils.now();
                const owned_text = try alloc.dupe(u8, text);
                const owned_details = try alloc.dupe(u8, options.details);

                const item: Child.Item = .{
                    .text = owned_text,
                    .details = owned_details,
                    .created = now,
                    .modified = now,
                    .due = options.due,
                    .importance = options.importance,
                    .tags = try utils.emptyTagList(alloc),
                };

                try self.collection.addItem(&self.item, item);
            }

            pub fn remove(self: *@This(), item: Child.Item) !void {
                const index = for (self.item.children.?, 0..) |i, j| {
                    if (i.created == item.created) break j;
                } else unreachable; // todo
                utils.moveToEnd(Child.Item, self.item.children.?, index);
                self.item.children.?.len -= 1;
                try self.collection.content.putMove(
                    self.item.info.name,
                    self.item.children.?,
                );
            }
        };
    }
};

pub const DirectoryCollection = CollectionTemplate(Directory);
pub const JournalCollection = CollectionTemplate(Journal);
pub const TaskListCollection = CollectionTemplate(TaskListDetails);

pub const Ordering = enum { Modified, Created };
