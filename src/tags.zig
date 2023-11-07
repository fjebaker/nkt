const std = @import("std");
const Topology = @import("collections/Topology.zig");

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

    pub fn deinit(c: *ContextParse) void {
        c.alloc.free(c.positions);
        c.* = undefined;
    }

    pub fn nameIterator(c: *const ContextParse) NameIterator {
        return .{ .ctx = c };
    }

    pub fn getName(c: *const ContextParse, index: usize) []const u8 {
        const pos = c.positions[index];
        return c.string[pos.start + 1 .. pos.end];
    }

    fn tagNameValid(name: []const u8, allowed_tags: []const TagInfo) !void {
        for (allowed_tags) |tag| {
            if (std.mem.eql(u8, tag.name, name)) {
                return;
            }
        }
        return TagError.InvalidTag;
    }

    pub fn validateAgainst(
        c: *const ContextParse,
        allowed_tags: []const TagInfo,
    ) !void {
        var names = c.nameIterator();
        while (names.next()) |name| {
            try tagNameValid(name, allowed_tags);
        }
    }
};

fn testContextValidation(names: []const []const u8, allowed: []const TagInfo) !void {
    for (names) |name| {
        try ContextParse.tagNameValid(name, allowed);
    }
}

test "context validation" {
    const allowed = [_]TagInfo{
        TagInfo{ .name = "something", .created = 0, .color = "red" },
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

pub fn parseTagString(string: []const u8) ![]const u8 {
    std.debug.assert(string[0] == '@');
    var itt = Iterator{ .string = string[1..] };
    try readUntilEndOfTag(&itt);

    if (itt.index - 1 == 0) return TagError.InvalidTag;
    return string[0..itt.index];
}

fn testParseTagString(string: []const u8, comptime expected: ?[]const u8) !void {
    const s = parseTagString(string) catch null;
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
    var color = getTagColorContext(taginfos, context, tag_index);

    // todo: this would work much better as a while loop
    for (0.., string) |i, c| {
        const current = context.positions[tag_index];
        if (i == current.start) {
            _ = try writer.writeAll(color.start);
        }
        if (i == current.end) {
            _ = try writer.writeAll(color.end);

            tag_index += 1;
            if (tag_index >= context.positions.len) {
                // no colourizing left, so just write everything and break
                _ = try writer.writeAll(string[i..]);
                break;
            }
            color = getTagColorContext(taginfos, context, tag_index);
        }
        _ = try writer.writeByte(c);
    }
}

const TagColor = struct { start: []const u8, end: []const u8 };
fn getTagColorContext(
    infos: []const TagInfo,
    ctx: ContextParse,
    index: usize,
) TagColor {
    const name = ctx.getName(index);
    const cham = getTagColor(infos, name).?;
    return .{ .start = cham.open, .end = cham.close };
}

pub fn getTagColor(infos: []const TagInfo, name: []const u8) ?Chameleon {
    const tag = getTag(infos, name) orelse
        return null;
    return tagColor(tag.color);
}

pub const TagWriter = struct {
    data: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    taginfo: []const TagInfo,

    pub fn init(alloc: std.mem.Allocator, taginfo: []const TagInfo) TagWriter {
        var data = std.ArrayList(u8).init(alloc);
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

const ColorName = enum {
    yellow,
    orange,
    green,
    red,
    magenta,
    cyan,
    blue,
};

fn tagColor(name: []const u8) Chameleon {
    comptime var cham = Chameleon.init(.Auto).bold();

    return switch (std.meta.stringToEnum(ColorName, name) orelse return cham) {
        .yellow => cham.yellowBright(),
        .orange => cham.rgb(238, 137, 62),
        .green => cham.greenBright(),
        .red => cham.redBright(),
        .magenta => cham.magentaBright(),
        .cyan => cham.cyanBright(),
        .blue => cham.blueBright(),
    };
}
