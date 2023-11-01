const std = @import("std");
const Chameleon = @import("chameleon").Chameleon;

const Printer = @import("Printer.zig");

const StringList = std.ArrayList(u8);

fn ChildType(comptime T: anytype) type {
    const info = @typeInfo(T);
    if (info == .Optional) {
        return @typeInfo(info.Optional.child).Pointer.child;
    } else {
        return info.Pointer.child;
    }
}

pub const Writer = StringList.Writer;
pub const WriteError = error{ OutOfMemory, DateError };
pub const PrinterError = error{HeadingMissing};

const STRIDE = 80;

const Chunk = struct {
    heading: []const u8,
    lines: StringList,

    fn print(self: *Chunk, writer: anytype, pretty: bool, indent: usize) !void {
        _ = try writer.writeByteNTimes(' ', indent);
        if (pretty) {
            comptime var cham = Chameleon.init(.Auto);
            try writer.print(cham.underline().fmt("{s}"), .{self.heading});
        } else {
            try writer.print("{s}", .{self.heading});
        }
        const content = std.mem.trim(
            u8,
            try self.lines.toOwnedSlice(),
            "\n",
        );
        if (indent != 0) {
            var lines = std.mem.split(u8, content, "\n");

            while (lines.next()) |line| {
                var itt = std.mem.window(u8, line, STRIDE, STRIDE);
                while (itt.next()) |chunk| {
                    _ = try writer.writeAll("\n");
                    _ = try writer.writeByteNTimes(' ', indent);
                    _ = try writer.writeAll(chunk);
                }
            }
        } else {
            _ = try writer.writeAll(content);
        }
    }
};

const ChunkList = std.ArrayList(Chunk);

remaining: ?usize,
mem: std.heap.ArenaAllocator,
chunks: ChunkList,
current: ?*Chunk = null,
pretty: bool,
indent: usize = 0,

pub fn init(alloc: std.mem.Allocator, N: ?usize, pretty: bool) Printer {
    var mem = std.heap.ArenaAllocator.init(alloc);
    errdefer mem.deinit();

    var list = ChunkList.init(alloc);

    return .{
        .remaining = N,
        .chunks = list,
        .mem = mem,
        .pretty = pretty,
    };
}

pub fn drain(self: *const Printer, writer: anytype) !void {
    if (self.indent > 0) _ = try writer.writeAll("\n");

    var chunks = self.chunks.items;
    // print first chunk
    if (chunks.len > 0) {
        try chunks[0].print(writer, self.pretty, self.indent);
    }
    if (chunks.len > 1) {
        for (chunks[1..]) |*chunk| {
            _ = try writer.writeAll("\n");
            try chunk.print(writer, self.pretty, self.indent);
        }
    }
    if (self.indent > 0) _ = try writer.writeAll("\n");
    _ = try writer.writeAll("\n");
}

fn subRemainder(self: *Printer, i: usize) bool {
    if (self.remaining == null) return true;
    self.remaining.? -= i;
    return self.remaining.? != 0;
}

fn allowMore(self: *const Printer) bool {
    if (self.remaining) |rem| {
        return rem > 0;
    }
    return true;
}

pub fn reverse(self: *Printer) void {
    std.mem.reverse(Chunk, self.chunks.items);
}

pub fn addItems(
    self: *Printer,
    items: anytype,
    comptime write_function: fn (writer: Writer, item: ChildType(@TypeOf(items))) WriteError!void,
) !bool {
    const Wrapper = struct {
        pub fn write_function_wrapper(
            _: void,
            writer: Writer,
            item: ChildType(@TypeOf(items)),
        ) WriteError!void {
            return write_function(writer, item);
        }
    };
    return self.addItemsCtx(void, items, Wrapper.write_function_wrapper, {});
}

pub fn addItemsCtx(
    self: *Printer,
    comptime ContextType: type,
    items: anytype,
    comptime write_function: fn (ContextType, writer: Writer, item: ChildType(@TypeOf(items))) WriteError!void,
    context: ContextType,
) !bool {
    const _items = if (@typeInfo(@TypeOf(items)) == .Optional) items.? else items;
    var chunk = self.current orelse return PrinterError.HeadingMissing;

    var writer = chunk.lines.writer();

    const start = if (self.remaining) |rem|
        (_items.len -| rem)
    else
        0;

    for (_items[start..]) |item| {
        try write_function(context, writer, item);
    }

    return self.subRemainder(_items.len - start);
}

pub fn addInfoLine(
    self: *Printer,
    c1: ?Chameleon,
    name: []const u8,
    c2: ?Chameleon,
    comptime value_fmt: []const u8,
    args: anytype,
) !bool {
    var chunk = self.current orelse return PrinterError.HeadingMissing;

    if (self.allowMore()) {
        if (self.pretty) {
            if (c1) |c| _ = try chunk.lines.writer().writeAll(c.open);
            try chunk.lines.writer().print("{s: <12}: ", .{name});
            if (c1) |c| _ = try chunk.lines.writer().writeAll(c.close);

            if (c2) |c| _ = try chunk.lines.writer().writeAll(c.open);
            try chunk.lines.writer().print(value_fmt, args);
            if (c2) |c| _ = try chunk.lines.writer().writeAll(c.close);
        } else {
            try chunk.lines.writer().print("{s: <12}: ", .{name});
            try chunk.lines.writer().print(value_fmt, args);
        }
    }
    return self.subRemainder(1);
}

pub fn addLine(self: *Printer, comptime format: []const u8, args: anytype) !bool {
    var chunk = self.current orelse return PrinterError.HeadingMissing;

    if (self.allowMore()) {
        try chunk.lines.writer().print(format, args);
    }
    return self.subRemainder(1);
}

pub fn addFormattedLine(
    self: *Printer,
    cm: Chameleon,
    comptime format: []const u8,
    args: anytype,
) !bool {
    var chunk = self.current orelse return PrinterError.HeadingMissing;

    if (self.allowMore()) {
        if (self.pretty) _ = try chunk.lines.writer().writeAll(cm.open);
        try chunk.lines.writer().print(format, args);
        if (self.pretty) _ = try chunk.lines.writer().writeAll(cm.close);
    }
    return self.subRemainder(1);
}

pub fn addHeading(self: *Printer, comptime format: []const u8, args: anytype) !void {
    var alloc = self.mem.allocator();

    var heading_writer = StringList.init(alloc);
    var lines = StringList.init(alloc);

    try heading_writer.writer().print(format, args);

    var chunk: Chunk = .{
        .heading = try heading_writer.toOwnedSlice(),
        .lines = lines,
    };
    try self.chunks.append(chunk);

    self.current = &self.chunks.items[self.chunks.items.len - 1];
}

pub fn deinit(self: *Printer) void {
    self.chunks.deinit();
    self.mem.deinit();
    self.* = undefined;
}

pub fn couldFit(self: *Printer, size: usize) bool {
    if (self.remaining) |rem| {
        return rem >= size;
    }
    return true;
}
