const std = @import("std");
const Topology = @import("Topology.zig");

const utils = @import("utils.zig");
const colors = @import("colors.zig");

const Chameleon = @import("chameleon").Chameleon;

pub const TagInfo = Topology.TagInfo;
pub const Tag = Topology.Tag;

pub const ContextError = error{ InvalidCharacter, NotLowercase };
pub const TagError = error{ InvalidTag, DuplicateTag };

pub const ContextParse = struct {
    pub const Position = struct { start: usize, end: usize };

    pub const NameIterator = struct {
        ctx: *const ContextParse,
        index: usize = 0,

        pub fn next(itt: *NameIterator) ?[]const u8 {
            if (itt.index >= itt.ctx.positions.len)
                return null;
            itt.index += 1;
            return itt.ctx.getName(itt.index - 1);
        }
    };

    alloc: std.mem.Allocator,
    positions: []Position,
    string: []const u8,
    mem: ?std.heap.ArenaAllocator = null,

    pub fn deinit(c: *ContextParse) void {
        c.alloc.free(c.positions);
        if (c.mem) |*m| m.deinit();
        c.* = undefined;
    }

    pub fn nameIterator(c: *const ContextParse) NameIterator {
        return .{ .ctx = c };
    }

    pub fn getName(c: *const ContextParse, index: usize) []const u8 {
        const pos = c.positions[index];
        return c.string[pos.start + 1 .. pos.end];
    }

    fn arenaAlloc(c: *ContextParse) std.mem.Allocator {
        if (c.mem) |*m| return m.allocator();
        c.mem = std.heap.ArenaAllocator.init(c.alloc);
        return c.mem.?.allocator();
    }

    /// Transfrom the `ContextParse` into a tag list, validating against the allowed tags.
    pub fn getTags(c: *ContextParse, allowed_tags: []const TagInfo) ![]Tag {
        var alloc = c.arenaAlloc();
        var tags = try alloc.alloc(Tag, c.positions.len);

        const now = utils.now();

        var i: usize = 0;
        var names = c.nameIterator();
        while (names.next()) |name| {
            tags[i] = try validateTag(name, allowed_tags, now);
            i += 1;
        }

        return tags;
    }

    pub fn validateAgainst(
        c: *const ContextParse,
        allowed_tags: []const TagInfo,
    ) !void {
        var names = c.nameIterator();
        while (names.next()) |name| {
            if (!tagNameValid(name, allowed_tags)) {
                return TagError.InvalidTag;
            }
        }
    }
};

fn tagNameValid(name: []const u8, allowed_tags: []const TagInfo) bool {
    for (allowed_tags) |tag| {
        if (std.mem.eql(u8, tag.name, name)) {
            return true;
        }
    }
    return false;
}

/// Validates the tagname in `name` with the allowed tags `allowed_tags`. If
/// the tag is valid, returns a new tag with creation time set to `now`.
pub fn validateTag(
    name: []const u8,
    allowed_tags: []const TagInfo,
    now: u64,
) !Tag {
    if (!tagNameValid(name, allowed_tags)) {
        return TagError.InvalidTag;
    }
    return .{ .name = name, .added = now };
}

/// Validate and create a tag list from a list of strings given a set of allowed tag infos.
pub fn makeTagList(
    alloc: std.mem.Allocator,
    names: []const []const u8,
    allowed_tags: []const TagInfo,
) ![]Tag {
    const now = utils.now();

    var tags = try alloc.alloc(Tag, names.len);
    errdefer alloc.free(tags);

    for (tags, names) |*tag, name| {
        tag.* = try validateTag(name, allowed_tags, now);
    }

    return tags;
}

fn testContextValidation(names: []const []const u8, allowed: []const TagInfo) !void {
    for (names) |name| {
        if (!tagNameValid(name, allowed)) {
            return TagError.InvalidTag;
        }
    }
}

test "context validation" {
    const allowed = [_]TagInfo{
        TagInfo{ .name = "something", .created = 0, .color = colors.C_RED },
    };
    try testContextValidation(&.{"something"}, &allowed);
    testContextValidation(&.{"smthg"}, &allowed) catch |err| {
        try std.testing.expectEqual(TagError.InvalidTag, err);
    };
}

fn getContextName(word: []const u8) !?[]const u8 {
    if (word[0] == '@') {
        for (word[1..], 1..) |c, end| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                if (!std.ascii.isLower(c)) return ContextError.NotLowercase;
            } else return word[1 .. end - 1];
        }
        return word[1..];
    }
    return null;
}

const Iterator = struct {
    string: []const u8,
    index: usize = 0,
    pub fn next(itt: *Iterator) ?u8 {
        if (itt.index >= itt.string.len) {
            itt.index += 1;
            return null;
        }
        itt.index += 1;
        return itt.string[itt.index - 1];
    }
};

fn readUntilEndOfTag(itt: *Iterator) !void {
    while (itt.next()) |o| {
        if (o == '-') return ContextError.InvalidCharacter;
        if (std.ascii.isAlphanumeric(o) or o == '_') {
            if (!std.ascii.isLower(o)) return ContextError.NotLowercase;
            continue;
        }

        break;
    }
}

pub fn parseContextString(string: []const u8) ![]const u8 {
    std.debug.assert(string[0] == '@');
    var itt = Iterator{ .string = string[1..] };
    try readUntilEndOfTag(&itt);

    if (itt.index - 1 == 0) return TagError.InvalidTag;
    return string[0..itt.index];
}

fn testParseTagString(string: []const u8, comptime expected: ?[]const u8) !void {
    const s = parseContextString(string) catch null;
    if (s) |s_| {
        try std.testing.expectEqualStrings(expected.?, s_);
    } else {
        try std.testing.expectEqual(s, expected);
    }
}

test "tag strings" {
    try testParseTagString("@name", "@name");
    try testParseTagString("@name asjdhasjkd", "@name");
    try testParseTagString("@name.", "@name");
}

pub fn parseContexts(allocator: std.mem.Allocator, string: []const u8) !ContextParse {
    var positions = std.ArrayList(ContextParse.Position).init(allocator);
    errdefer positions.deinit();

    var itt = Iterator{ .string = string };

    while (itt.next()) |c| {
        if (c == '@') {
            const start = itt.index - 1;
            try readUntilEndOfTag(&itt);
            try positions.append(
                .{ .start = start, .end = itt.index - 1 },
            );
        }
    }

    return .{
        .alloc = allocator,
        .positions = try positions.toOwnedSlice(),
        .string = string, // todo: actually do the `\\@` escaping
    };
}

fn testContextParse(
    input: []const u8,
    expected: []const []const u8,
    positions: []const ContextParse.Position,
) !void {
    var contexts = try parseContexts(std.testing.allocator, input);
    defer contexts.deinit();

    var names = contexts.nameIterator();
    while (names.next()) |name| {
        const exp = expected[names.index - 1];
        try std.testing.expectEqualStrings(exp, name);
    }
    for (contexts.positions, positions) |parsed, exp| {
        try std.testing.expectEqualDeep(exp, parsed);
    }
}

fn testContextParseFail(input: []const u8, expected: anyerror) !void {
    _ = parseContexts(std.testing.allocator, input) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    try std.testing.expect(false);
}

test "context parsing" {
    try testContextParse(
        "this is @something that needs to be @done",
        &.{ "something", "done" },
        &[_]ContextParse.Position{
            .{ .start = 8, .end = 18 },
            .{ .start = 36, .end = 41 },
        },
    );
    try testContextParse(
        "this is @something that needs to be @done!",
        &.{ "something", "done" },
        &[_]ContextParse.Position{
            .{ .start = 8, .end = 18 },
            .{ .start = 36, .end = 41 },
        },
    );
    try testContextParse(
        "this is something that needs to be done",
        &.{},
        &.{},
    );

    try testContextParseFail(
        "this is @Done",
        ContextError.NotLowercase,
    );

    try testContextParseFail(
        "this is @d-one",
        ContextError.InvalidCharacter,
    );
}

pub fn getTag(taginfos: []const TagInfo, name: []const u8) ?TagInfo {
    for (taginfos) |info| {
        if (std.mem.eql(u8, info.name, name)) {
            return info;
        }
    }
    return null;
}

pub fn prettyPrint(
    alloc: std.mem.Allocator,
    writer: anytype,
    string: []const u8,
    taginfos: []const TagInfo,
) !void {
    var context = try parseContexts(alloc, string);
    defer context.deinit();

    if (context.positions.len == 0 or taginfos.len == 0) {
        _ = try writer.writeAll(string);
        return;
    }

    var tag_index: usize = 0;
    var color = getTagColorContext(alloc, taginfos, context, tag_index);

    // todo: this would work much better as a while loop
    for (0.., string) |i, c| {
        const current = context.positions[tag_index];
        if (i == current.start) {
            try color.writeOpen(writer);
        }
        if (i == current.end) {
            try color.writeClose(writer);

            tag_index += 1;
            if (tag_index >= context.positions.len) {
                // no colourizing left, so just write everything and break
                _ = try writer.writeAll(string[i..]);
                break;
            }

            color.deinit();
            color = getTagColorContext(alloc, taginfos, context, tag_index);
        }
        _ = try writer.writeByte(c);
    }
}

fn getTagColorContext(
    alloc: std.mem.Allocator,
    infos: []const TagInfo,
    ctx: ContextParse,
    index: usize,
) colors.Farbe {
    const name = ctx.getName(index);
    const fmt = (try getTagFormat(alloc, infos, name)).?;
    return fmt;
}

pub fn getTagFormat(alloc: std.mem.Allocator, infos: []const TagInfo, name: []const u8) !?colors.Farbe {
    const tag = getTag(infos, name) orelse
        return null;
    var f = try tag.color.toFarbe(alloc);
    errdefer f.deinit();
    try f.bold();
    return f;
}

pub const TagWriter = struct {
    data: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    taginfo: []const TagInfo,

    pub fn init(alloc: std.mem.Allocator, taginfo: []const TagInfo) TagWriter {
        const data = std.ArrayList(u8).init(alloc);
        return .{ .data = data, .alloc = alloc, .taginfo = taginfo };
    }

    pub fn writer(tw: *TagWriter) std.ArrayList(u8).Writer {
        return tw.data.writer();
    }

    pub fn drain(tw: *TagWriter, out_writer: anytype) !void {
        const string = try tw.data.toOwnedSlice();
        defer tw.alloc.free(string);

        try prettyPrint(tw.alloc, out_writer, string, tw.taginfo);

        // init for later use
        tw.data = std.ArrayList(u8).init(tw.alloc);
    }

    pub fn deinit(tw: *TagWriter) void {
        tw.data.deinit();
        tw.* = undefined;
    }
};

/// Add tags `new` to `existing`
pub fn addTags(alloc: std.mem.Allocator, existing: *[]Tag, new: []const Tag) !void {
    var maximal = std.StringArrayHashMap(Tag).init(alloc);
    defer maximal.deinit();

    // add current
    for (existing.*) |t| {
        try maximal.put(t.name, t);
    }
    // add new
    for (new) |t| {
        try maximal.put(t.name, t);
    }

    existing.* = try alloc.dupe(Tag, maximal.values());
}

const ColorName = enum {
    blue,
    brown,
    cyan,
    green,
    magenta,
    orange,
    pink,
    red,
    salmon,
    yellow,
};

fn tagColor(name: []const u8) Chameleon {
    comptime var cham = Chameleon.init(.Auto).bold();

    return switch (std.meta.stringToEnum(ColorName, name) orelse return cham) {
        .blue => cham.blueBright(),
        .brown => cham.rgb(194, 101, 100),
        .cyan => cham.cyanBright(),
        .green => cham.greenBright(),
        .magenta => cham.magentaBright(),
        .orange => cham.rgb(238, 137, 62),
        .pink => cham.rgb(255, 126, 126),
        .red => cham.redBright(),
        .salmon => cham.rgb(235, 136, 186),
        .yellow => cham.yellowBright(),
    };
}
