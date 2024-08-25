const std = @import("std");

const FormatPrinter = @import("FormatPrinter.zig");
const colors = @import("../colors.zig");
const Farbe = colors.Farbe;

const BlockPrinter = @import("BlockPrinter.zig");

pub const Error = error{NoCurrentBlock};

pub const Block = struct {
    parent: *FormatPrinter,
    start_index: usize,
    end_index: usize,

    pub fn write(b: Block, writer: anytype, pretty: bool) !void {
        for (b.start_index..b.end_index) |i| {
            const entry = b.parent.texts.items[i];
            try entry.write(writer, pretty);
        }
    }
};

current: ?*Block = null,
format_printer: FormatPrinter,
blocks: std.ArrayList(Block),

pub fn init(
    alloc: std.mem.Allocator,
    opts: FormatPrinter.Options,
) BlockPrinter {
    const fp = FormatPrinter.init(alloc, opts);
    const blocks = std.ArrayList(Block).init(alloc);
    return .{ .format_printer = fp, .blocks = blocks };
}

pub fn deinit(bp: *BlockPrinter) void {
    bp.format_printer.deinit();
    bp.blocks.deinit();
    bp.* = undefined;
}

pub fn addBlock(bp: *BlockPrinter, text: []const u8, opts: FormatPrinter.TextOptions) !void {
    try bp.format_printer.addText(text, opts);
    const end = bp.format_printer.texts.items.len;

    const index = if (bp.current) |b| b.end_index else 0;
    try bp.blocks.append(
        .{
            .parent = &bp.format_printer,
            .start_index = index,
            .end_index = end,
        },
    );
    bp.current = &bp.blocks.items[bp.blocks.items.len - 1];
}

pub fn addToCurrent(bp: *BlockPrinter, text: []const u8, opts: FormatPrinter.TextOptions) !void {
    if (bp.current == null) return Error.NoCurrentBlock;

    try bp.format_printer.addText(text, opts);
    const end = bp.format_printer.texts.items.len;

    bp.current.?.end_index = end;
}

const HEADING_FORMAT = (colors
    .Farbe.init()
    .fgRgb(205, 175, 102)
    .bold());

pub fn addFormatted(
    bp: *BlockPrinter,
    what: enum { Heading, Item },
    comptime fmt: []const u8,
    args: anytype,
    opts: FormatPrinter.TextOptions,
) !void {
    var alloc = bp.format_printer.mem.child_allocator;

    const string = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(string);

    switch (what) {
        .Heading => {
            var new_opts = opts;
            new_opts.fmt = new_opts.fmt orelse HEADING_FORMAT;
            try bp.addBlock(string, new_opts);

            new_opts.fmt = null;
            new_opts.is_counted = false;
            try bp.addToCurrent("\n\n", new_opts);
        },
        .Item => try bp.addToCurrent(string, opts),
    }
}

pub fn reverse(bp: *BlockPrinter) void {
    std.mem.reverse(Block, bp.blocks.items);
    bp.current = null;
}

pub fn remaining(bp: *const BlockPrinter) ?usize {
    return bp.format_printer.opts.max_lines;
}

pub fn couldFit(bp: *const BlockPrinter, n: usize) bool {
    const rem = bp.remaining() orelse return true;
    return rem >= n;
}

pub fn drain(bp: *const BlockPrinter, writer: anytype) !void {
    if (bp.blocks.items.len == 0) return;

    try writer.writeAll("\n");
    try bp.blocks.items[0].write(writer, bp.format_printer.opts.pretty);

    if (bp.blocks.items.len == 1) {
        try writer.writeAll("\n");
        return;
    }

    for (bp.blocks.items[1..]) |block| {
        try writer.writeAll("\n");
        try block.write(writer, bp.format_printer.opts.pretty);
    }
    try writer.writeAll("\n");
}
