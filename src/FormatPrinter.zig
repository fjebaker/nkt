const std = @import("std");
const tags = @import("topology/tags.zig");
const utils = @import("utils.zig");
const colors = @import("colors.zig");

const FormatPrinter = @import("FormatPrinter.zig");

/// Tracks the formatting applied to the text object. Limited to up to 5
/// stacked color / style specifiers.
pub const Farbe = colors.Farbe;

pub const RichText = struct {
    text: []const u8,
    fmt: ?Farbe,
    pub fn write(t: RichText, writer: anytype, pretty: bool) !void {
        if (pretty and t.fmt != null) {
            try t.fmt.?.write(writer, "{s}", .{t.text});
        } else {
            _ = try writer.writeAll(t.text);
        }
    }
};

pub const Options = struct {
    indent: usize = 0,
    max_lines: ?usize = null, // null for no limit
    pretty: bool = true,
    tag_descriptors: ?[]const tags.Tag.Descriptor = null,
};

mem: std.heap.ArenaAllocator,
texts: std.ArrayList(RichText),
opts: Options,

pub fn init(alloc: std.mem.Allocator, opts: Options) FormatPrinter {
    return .{
        .mem = std.heap.ArenaAllocator.init(alloc),
        .texts = std.ArrayList(RichText).init(alloc),
        .opts = opts,
    };
}

pub fn deinit(fp: *FormatPrinter) void {
    fp.mem.deinit();
    fp.texts.deinit();
    fp.* = undefined;
}

pub fn add(fp: *FormatPrinter, rich: RichText) !void {
    try fp.texts.append(rich);
}

const PRE_COLOR = colors.ComptimeFarbe.init().bgRgb(48, 48, 48).fgRgb(236, 106, 101);
const URI_COLOR = colors.ComptimeFarbe.init().fgRgb(58, 133, 134).underlined();

/// Get the `Farbe` attributed to a given tag from the list of tag descriptors.
pub fn getTagFormat(
    allocator: std.mem.Allocator,
    tag_descriptors: []const tags.Tag.Descriptor,
    tag_name: []const u8,
) !?Farbe {
    const descriptor: tags.Tag.Descriptor = for (tag_descriptors) |td| {
        if (std.mem.eql(u8, td.name, tag_name)) {
            break td;
        }
    } else return null;

    var f = try descriptor.color.toFarbe(allocator);
    errdefer f.deinit();
    try f.bold();
    return f;
}

fn identifySubBlock(fp: *FormatPrinter, parser: *Parser) !?Block {
    const text = parser.text;
    const start = parser.i - 1;
    const allocator = fp.mem.allocator();
    switch (text[start]) {
        '@' => {
            if (tags.getTagString(text[start..]) catch null) |tag_name| {
                const tag_descriptors = fp.opts.tag_descriptors orelse
                    return null;

                const fmt = (try getTagFormat(
                    allocator,
                    tag_descriptors,
                    tag_name,
                )) orelse
                    return null;

                const end = tag_name.len + start + 1;
                parser.skipN(end - start - 1);
                return .{ .mark = .Tag, .start = start, .end = end, .fmt = fmt };
            }
        },
        '`' => {
            const lookahead = parser.peekSlice(2);
            if (lookahead) |la| {
                if (la[0] == '`' and la[1] == '`') {
                    parser.skipN(2);
                    return null;
                }
            }
            const index = std.mem.indexOfScalarPos(u8, text, start + 1, '`');
            if (index) |end| {
                parser.skipN(end + 1 - start);
                return .{
                    .mark = .Pre,
                    .start = start,
                    .end = end + 1,
                    .fmt = PRE_COLOR.runtime(allocator),
                };
            }
        },
        ':' => {
            if (utils.findUriFromColon(text, start)) |uri| {
                parser.skipN(uri.end - start);
                return .{
                    .mark = .Uri,
                    .start = uri.start,
                    .end = uri.end,
                    .fmt = URI_COLOR.runtime(allocator),
                };
            }
        },
        else => {},
    }
    return null;
}

const Block = struct {
    start: usize,
    end: usize,
    fmt: Farbe,
    mark: ?enum { Tag, Pre, Uri } = null,
};

const Parser = struct {
    i: usize = 0,
    text: []const u8,
    stack: std.ArrayList(Block),

    pub fn init(
        alloc: std.mem.Allocator,
        text: []const u8,
    ) Parser {
        return .{
            .text = text,
            .stack = std.ArrayList(Block).init(alloc),
        };
    }

    pub fn deinit(p: *Parser) void {
        p.stack.deinit();
        p.* = undefined;
    }

    pub fn current(p: *const Parser) usize {
        return p.i -| 1;
    }

    pub fn push(p: *Parser, block: Block) !void {
        try p.stack.append(block);
    }

    pub fn pop(p: *Parser) Block {
        return p.stack.pop();
    }

    pub fn popOrNull(p: *Parser) ?Block {
        return p.stack.popOrNull();
    }

    pub fn next(p: *Parser) ?u8 {
        const i = p.nextIndex() orelse
            return null;
        return p.text[i];
    }

    pub fn nextIndex(p: *Parser) ?usize {
        if (p.i >= p.text.len)
            return null;
        const i = p.i;
        p.i += 1;
        return i;
    }

    pub fn peek(p: *const Parser) ?u8 {
        if (p.i >= p.text.len)
            return null;
        return p.text[p.i];
    }

    pub fn peekSlice(p: *const Parser, n: usize) ?[]const u8 {
        if (p.i + n >= p.text.len)
            return null;
        return p.text[p.i .. p.i + n];
    }

    pub fn skipN(p: *Parser, n: usize) void {
        p.i += n;
    }
};

fn addTextImpl(
    fp: *FormatPrinter,
    text: []const u8,
    fmt: Farbe,
    count: bool,
) !void {
    var parser = Parser.init(fp.mem.child_allocator, text);
    defer parser.deinit();

    var current: Block = .{ .start = 0, .end = text.len, .fmt = fmt };
    while (parser.nextIndex()) |i| {
        if (i >= current.end) {
            // when we've reached the end of the currently scanned block, write
            // it to the output with its format
            try fp.add(
                .{ .text = text[current.start..current.end], .fmt = current.fmt },
            );
            // retrieve the previous block
            current = parser.pop();
            if (i >= text.len) break;
            continue;
        }

        if (try fp.identifySubBlock(&parser)) |sub_block| {
            // we found a new block so write everything that we've scanned of
            // the current block so far
            try fp.add(.{
                .text = text[current.start..sub_block.start],
                .fmt = current.fmt,
            });

            // wherever the new block ends is the start of the new current
            // block
            current.start = sub_block.end;

            // save current to get it back later
            try parser.push(current);
            current = sub_block;
        }
    }

    try fp.add(
        .{ .text = text[current.start..current.end], .fmt = current.fmt },
    );

    while (parser.popOrNull()) |b| {
        try fp.add(
            .{ .text = text[b.start..b.end], .fmt = b.fmt },
        );
    }

    if (count) {
        if (fp.opts.max_lines) |*counter| {
            counter.* -= 1;
        }
    }
}

pub const TextOptions = struct {
    fmt: ?Farbe = null,
    is_counted: bool = true,
};

pub fn addText(fp: *FormatPrinter, text: []const u8, opts: TextOptions) !void {
    if (text.len == 0) return;
    // store a copy
    var alloc = fp.mem.allocator();
    const fmt = opts.fmt orelse Farbe.init(alloc);
    try fp.addTextImpl(try alloc.dupe(u8, text), fmt, opts.is_counted);
}

pub fn addFmtText(
    fp: *FormatPrinter,
    comptime fmt: []const u8,
    args: anytype,
    opts: TextOptions,
) !void {
    var alloc = fp.mem.child_allocator;

    const string = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(string);

    try fp.addText(string, opts);
}

pub fn addNTimes(fp: *FormatPrinter, char: u8, n: usize, opts: TextOptions) !void {
    var alloc = fp.mem.child_allocator;

    const string = try alloc.alloc(u8, n);
    defer alloc.free(string);
    for (string) |*c| c.* = char;
    try fp.addText(string, opts);
}

pub fn drain(fp: *FormatPrinter, writer: anytype) !void {
    for (fp.texts.items) |item| {
        try item.write(writer, fp.opts.pretty);
    }
}
