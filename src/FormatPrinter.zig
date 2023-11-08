const std = @import("std");
const tags = @import("tags.zig");
const utils = @import("utils.zig");

const Chameleon = @import("chameleon").Chameleon;

const FormatPrinter = @import("FormatPrinter.zig");

const FormatSpecifier = struct {
    open: []const u8,
    close: []const u8,

    pub fn underline(
        spec: *FormatSpecifier,
        leaky_alloc: std.mem.Allocator,
    ) !void {
        comptime var cham = Chameleon.init(.Auto);
        const mod = cham.underline();
        spec.open = try std.mem.concat(leaky_alloc, u8, &.{ spec.open, mod.open });
        spec.close = try std.mem.concat(leaky_alloc, u8, &.{ spec.close, mod.close });
    }
};

const NO_FORMAT = FormatSpecifier{ .open = "", .close = "" };

pub const RichText = struct {
    text: []const u8,
    fmt: ?FormatSpecifier,
    pub fn write(t: RichText, writer: anytype, pretty: bool) !void {
        if (pretty) {
            if (t.fmt) |fmt| _ = try writer.writeAll(fmt.open);
        }
        _ = try writer.writeAll(t.text);
        if (pretty) {
            if (t.fmt) |fmt| _ = try writer.writeAll(fmt.close);
        }
    }
};

pub const Options = struct {
    indent: usize = 0,
    max_lines: ?usize = null, // null for no limit
    pretty: bool = true,
};

mem: std.heap.ArenaAllocator,
texts: std.ArrayList(RichText),
opts: Options,
tag_infos: ?[]const tags.TagInfo = null,

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

const PRE_FMT: FormatSpecifier = blk: {
    comptime var cham = Chameleon.init(.Auto);
    const c = cham.bgRgb(48, 48, 48).rgb(236, 106, 101);
    break :blk .{ .open = c.open, .close = c.close };
};

const URI_FMT: FormatSpecifier = blk: {
    comptime var cham = Chameleon.init(.Auto);
    const c = cham.rgb(58, 133, 134).underline();
    break :blk .{ .open = c.open, .close = c.close };
};

fn identifySubBlock(fp: *FormatPrinter, parser: *Parser) ?Block {
    const text = parser.text;
    const start = parser.i - 1;
    switch (text[start]) {
        '@' => {
            if (tags.parseContextString(text[start..]) catch null) |tag| {
                const tag_infos = fp.tag_infos orelse
                    return null;
                const cham = tags.getTagColor(tag_infos, tag[1..]) orelse
                    return null;
                const fmt = .{ .open = cham.open, .close = cham.close };
                const end = tag.len + start;
                parser.skipN(end - start);
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
                    .fmt = PRE_FMT,
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
                    .fmt = URI_FMT,
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
    fmt: FormatSpecifier,
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
    fmt: FormatSpecifier,
    count: bool,
) !void {
    var parser = Parser.init(fp.mem.child_allocator, text);
    defer parser.deinit();

    var current: Block = .{ .start = 0, .end = text.len, .fmt = fmt };
    while (parser.nextIndex()) |i| {
        if (i > current.end) {
            // write the formatted block
            try fp.add(
                .{ .text = text[current.start..current.end], .fmt = current.fmt },
            );
            current = parser.pop();
            if (i > text.len) break;
            continue;
        }

        if (fp.identifySubBlock(&parser)) |sub_block| {
            // write what we currently have
            try fp.add(.{
                .text = text[current.start..sub_block.start],
                .fmt = current.fmt,
            });

            // shift the start of the remaining
            current.start = parser.current();

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
    cham: ?Chameleon = null,
    is_counted: bool = true,
};

pub fn addText(fp: *FormatPrinter, text: []const u8, opts: TextOptions) !void {
    if (text.len == 0) return;
    const fmt: FormatSpecifier = if (opts.cham) |c|
        .{ .open = c.open, .close = c.close }
    else
        NO_FORMAT;

    // store a copy
    var alloc = fp.mem.allocator();
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

    var string = try alloc.alloc(u8, n);
    defer alloc.free(string);
    for (string) |*c| c.* = char;
    try fp.addText(string, opts);
}

pub fn drain(fp: *FormatPrinter, writer: anytype) !void {
    for (fp.texts.items) |item| {
        try item.write(writer, fp.opts.pretty);
    }
}
