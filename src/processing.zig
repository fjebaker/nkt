const std = @import("std");
const utils = @import("utils.zig");
const tags = @import("topology/tags.zig");

pub const Fragment = struct {
    text: []const u8,
    type: enum { normal, link, tag } = .normal,
};

const LINK_OPEN = "[[";
const LINK_CLOSE = "]]";

fn isLink(text: []const u8) ?[]const u8 {
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
                .link => i.start + i.fragment.text.len + 4,
                .tag => i.start + i.fragment.text.len + 1,
                .normal => i.start + i.fragment.text.len,
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
                if (isLink(text[loc + 2 ..])) |link| {
                    const end = loc + link.len;
                    const fragment: Fragment = .{
                        .text = text[loc + 2 .. end],
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
                        .text = text[loc + 1 .. end],
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

/// Split the text into a series of `Fragment` for processing.  Identifies
/// links via `[[LINK TEXT]]`
pub fn splitTextFragments(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]const Fragment {
    var list = std.ArrayList(Fragment).init(allocator);
    defer list.deinit();

    var start: usize = 0;
    var search_start: usize = 0;
    while (true) {
        if (nextFragment(text, search_start)) |f| {
            switch (f) {
                .f => |fragment| {
                    if (start != fragment.start) {
                        try list.append(
                            .{ .text = text[start..fragment.start] },
                        );
                    }
                    try list.append(fragment.fragment);

                    const end = fragment.end();
                    search_start = end;
                    start = end;
                },
                .offset => |off| search_start += off,
            }
        } else {
            if (start != text.len) {
                try list.append(.{ .text = text[start..] });
            }
            break;
        }
    }
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
        .{ .text = "thing", .type = .link },
        .{ .text = " world", .type = .normal },
    });

    try testFragments("[[thing]] world", &.{
        .{ .text = "thing", .type = .link },
        .{ .text = " world", .type = .normal },
    });

    try testFragments("world [[thing]]", &.{
        .{ .text = "world ", .type = .normal },
        .{ .text = "thing", .type = .link },
    });

    try testFragments("world [[thing  ]]", &.{
        .{ .text = "world ", .type = .normal },
        .{ .text = "thing  ", .type = .link },
    });

    try testFragments("world [[thi\nng]]", &.{
        .{ .text = "world [[thi\nng]]", .type = .normal },
    });

    try testFragments("hello @world", &.{
        .{ .text = "hello ", .type = .normal },
        .{ .text = "world", .type = .tag },
    });
}
