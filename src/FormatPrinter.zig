const std = @import("std");
const tags = @import("tags.zig");

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

const MarkedText = struct {
    mark: ?enum { Tag } = null,
    text: []const u8,
};

fn identifySubBlock(text: []const u8, start: usize) ?MarkedText {
    switch (text[start]) {
        // detect possible nests
        '@' => {
            if (tags.parseTagString(text[start..]) catch null) |tag| {
                return .{ .mark = .Tag, .text = tag };
            }
        },
        else => {},
    }
    return null;
}

const HelperFormat = struct {
    start: usize,
    end: usize,
    fmt: FormatSpecifier,
};

fn getFormat(fp: *FormatPrinter, marked: MarkedText) ?FormatSpecifier {
    if (marked.mark) |mark| switch (mark) {
        .Tag => {
            const tag_infos = fp.tag_infos orelse return null;
            const cham = tags.getTagColor(tag_infos, marked.text[1..]) orelse
                return null;
            return .{ .open = cham.open, .close = cham.close };
        },
    };
    return null;
}

fn addTextImpl(fp: *FormatPrinter, text: []const u8, fmt: FormatSpecifier, count: bool) !void {
    var stack = std.ArrayList(HelperFormat).init(fp.mem.child_allocator);
    defer stack.deinit();

    var current: HelperFormat = .{ .start = 0, .end = text.len, .fmt = fmt };

    for (0..text.len - 1) |i| {
        if (i > current.end) {
            // write the formatted block
            try fp.add(
                .{ .text = text[current.start..current.end], .fmt = current.fmt },
            );
            current = stack.pop();
            if (i > text.len) break;
            continue;
        }

        if (identifySubBlock(text, i)) |b| {
            const end = i + b.text.len;
            var maybe_new_fmt = fp.getFormat(b);
            var new_fmt = maybe_new_fmt orelse
                continue;

            if (std.mem.containsAtLeast(u8, current.fmt.open, 1, new_fmt.open)) {
                // we're already formatting this way, so modify the new
                // format so it's still distinct
                try new_fmt.underline(fp.mem.allocator());
            }

            // write what we currently have
            try fp.add(.{ .text = text[current.start..i], .fmt = current.fmt });
            // shift the start of the remaining
            current.start = end;

            // save current to get it back later
            try stack.append(current);
            current = .{ .start = i, .end = end, .fmt = new_fmt };
        }
    }

    try fp.add(
        .{ .text = text[current.start..current.end], .fmt = current.fmt },
    );

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
