const std = @import("std");
const utils = @import("../utils.zig");

pub const IndexContainer = std.AutoHashMap(usize, []const u8);

const IndexHelper = struct {
    modified: u64,
    name: []const u8,

    pub fn sortModified(_: void, lhs: IndexHelper, rhs: IndexHelper) bool {
        return lhs.modified < rhs.modified;
    }
};

const IndexSorter = utils.SortableList(IndexHelper, IndexHelper.sortModified);

pub fn makeIndex(alloc: std.mem.Allocator, items: anytype) !IndexContainer {
    const T = @TypeOf(items);
    const ChildType = @typeInfo(T).Pointer.child;
    const has_modified = @hasField(ChildType, "modified");
    const has_modified_call = @hasDecl(ChildType, "lastModified");
    const meets_criteria = @hasField(ChildType, "name") and (has_modified or has_modified_call);
    if (!meets_criteria) @compileError("Child of array must have 'modified' and 'name' fields");

    var index = IndexContainer.init(alloc);
    errdefer index.deinit();
    try index.ensureTotalCapacity(@intCast(items.len));

    var sorter = try IndexSorter.initSize(alloc, items.len);
    defer sorter.deinit();

    for (sorter.items, items) |*item, info| {
        const modified = if (has_modified)
            @field(info, "modified")
        else
            @call(.auto, @field(ChildType, "lastModified"), .{info});

        item.* = .{
            .modified = modified,
            .name = info.name,
        };
    }

    sorter.sort();
    sorter.reverse();

    for (0.., sorter.items) |i, item| {
        index.putAssumeCapacity(i, item.name);
    }

    return index;
}
