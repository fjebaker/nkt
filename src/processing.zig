const std = @import("std");
const utils = @import("utils.zig");
const tags = @import("topology/tags.zig");

pub const Fragment = struct {
    pub const Type = enum { normal, link, tag };

    text: []const u8,
    type: Type = .normal,

    pub fn inner(f: Fragment) []const u8 {
        const end = f.text.len;
        return switch (f.type) {
            .normal => f.text,
            .tag => f.text[1..],
            .link => f.text[2 .. end - 2],
        };
    }
};

test "fragment inner" {
    const f1 = Fragment{ .text = "[[hello]]", .type = .link };
    try std.testing.expectEqualStrings(
        "hello",
        f1.inner(),
    );
}

const LINK_OPEN = "[[";
const LINK_CLOSE = "]]";

fn getNoteLink(text: []const u8) ?[]const u8 {
    var itt = utils.Iterator(u8).init(text);

    var is_link: bool = false;
    while (itt.next()) |c| {
        switch (c) {
            '\n', '\r', '\t', '{', '(', '[' => break,
            ']' => {
                if (itt.peek()) |o| {
                    if (o == ']') {
                        _ = itt.next();
                        is_link = true;
                        break;
                    }
                }
                break;
            },
            else => {},
        }
    }

    if (!is_link) return null;
    const end = itt.index;
    return text[0..end];
}

const FragmentOrOffset = union(enum) {
    offset: usize,
    f: struct {
        start: usize,
        fragment: Fragment,

        fn end(i: @This()) usize {
            return switch (i.fragment.type) {
                inline else => i.start + i.fragment.text.len,
            };
        }
    },
};

fn nextFragment(text: []const u8, search_start: usize) ?FragmentOrOffset {
    var itt = utils.Iterator(u8).init(text);
    itt.index = search_start;
    while (itt.next()) |c| {
        switch (c) {
            '[' => {
                if (itt.peek()) |n| if (n != '[') continue;
                const loc = itt.index - 1;
                if (getNoteLink(text[loc + 2 ..])) |link| {
                    const end = loc + link.len + 2;
                    const fragment: Fragment = .{
                        .text = text[loc..end],
                        .type = .link,
                    };

                    return .{ .f = .{ .start = loc, .fragment = fragment } };
                }
                return .{ .offset = loc };
            },
            '@' => {
                const loc = itt.index - 1;
                if (tags.getTagString(text[loc..]) catch null) |tag_name| {
                    const end = loc + 1 + tag_name.len;
                    const fragment: Fragment = .{
                        .text = text[loc..end],
                        .type = .tag,
                    };

                    return .{ .f = .{ .start = loc, .fragment = fragment } };
                }
                return .{ .offset = loc };
            },
            else => {},
        }
    }
    return null;
}

fn addFragmentToList(
    list: *std.ArrayList(Fragment),
    fragment: Fragment,
) !void {
    try list.append(fragment);
}

/// Split the text into a series of `Fragment` for processing.  Identifies
/// links via `[[LINK TEXT]]`
pub fn splitTextFragments(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const Fragment {
    var list = std.ArrayList(Fragment).init(allocator);
    defer list.deinit();

    const P = Processor(*@TypeOf(list), addFragmentToList);
    var processor = P.init(&list);
    try processor.processText(text);

    return try list.toOwnedSlice();
}

fn testFragments(text: []const u8, comptime expected: []const Fragment) !void {
    const res = try splitTextFragments(std.testing.allocator, text);
    defer std.testing.allocator.free(res);
    try std.testing.expectEqualDeep(expected, res);
}

test "text fragments" {
    try testFragments("hello world", &.{
        .{ .text = "hello world", .type = .normal },
    });

    try testFragments("hello [[thing]] world", &.{
        .{ .text = "hello ", .type = .normal },
        .{ .text = "[[thing]]", .type = .link },
        .{ .text = " world", .type = .normal },
    });

    try testFragments("[[thing]] world", &.{
        .{ .text = "[[thing]]", .type = .link },
        .{ .text = " world", .type = .normal },
    });

    try testFragments("world [[thing]]", &.{
        .{ .text = "world ", .type = .normal },
        .{ .text = "[[thing]]", .type = .link },
    });

    try testFragments("world [[thing  ]]", &.{
        .{ .text = "world ", .type = .normal },
        .{ .text = "[[thing  ]]", .type = .link },
    });

    try testFragments("world [[thi\nng]]", &.{
        .{ .text = "world [[thi\nng]]", .type = .normal },
    });

    try testFragments("hello @world", &.{
        .{ .text = "hello ", .type = .normal },
        .{ .text = "@world", .type = .tag },
    });
}

pub fn Processor(
    comptime Ctx: type,
    comptime fragment_handler: fn (Ctx, Fragment) anyerror!void,
) type {
    //
    return struct {
        ctx: Ctx,

        const Self = @This();

        fn processFragment(
            self: *Self,
            fragment: Fragment,
        ) anyerror!void {
            return fragment_handler(self.ctx, fragment);
        }

        pub fn init(ctx: Ctx) Self {
            return .{ .ctx = ctx };
        }

        /// Process the text, calling the `fragment_handler` function for each
        /// fragment in the text.
        pub fn processText(self: *Self, text: []const u8) !void {
            var start: usize = 0;
            var search_start: usize = 0;
            while (true) {
                if (nextFragment(text, search_start)) |f| {
                    switch (f) {
                        .f => |fragment| {
                            if (start != fragment.start) {
                                try self.processFragment(
                                    .{ .text = text[start..fragment.start] },
                                );
                            }
                            try self.processFragment(fragment.fragment);

                            const end = fragment.end();
                            search_start = end;
                            start = end;
                        },
                        .offset => |off| search_start += off,
                    }
                } else {
                    if (start != text.len) {
                        try self.processFragment(.{ .text = text[start..] });
                    }
                    break;
                }
            }
        }
    };
}
