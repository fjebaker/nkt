const std = @import("std");
const selections = @import("../selections.zig");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const time = @import("../topology/time.zig");
const colors = @import("../colors.zig");

const stacks = @import("../topology/stacks.zig");
const Root = @import("../topology/Root.zig");

const commands = @import("../commands.zig");

pub const Push = struct {
    pub const short_help = "Push onto a stack";
    pub const long_help = short_help;
    pub const arguments = cli.Arguments(selections.selectHelp(
        "item",
        "The item to push to the stack (see `help select`)",
        .{ .required = true },
    ) ++
        &[_]cli.ArgumentDescriptor{
        .{
            .arg = "stack",
            .help = "Name of the stack to push to.",
            .required = true,
            .completion = "{compadd $(nkt completion list --collection stacks)}",
        },
        .{
            .arg = "index",
            .help = "The index position to insert into the stack. Index 0 is the default, and inserts the item at the top of the stack as the latest item.",
            .argtype = usize,
        },
        .{
            .arg = "-m/--message text",
            .help = "An additional message to attach to the item when pushed.",
        },
    });

    selection: selections.Selection,
    stack: []const u8,
    position: usize,
    message: ?[]const u8,

    pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Push {
        const args = try arguments.parseAll(itt);
        const selection = try selections.fromArgs(
            arguments.Parsed,
            args.item,
            args,
        );
        return .{
            .selection = selection,
            .stack = args.stack,
            .position = args.index orelse 0,
            .message = args.message,
        };
    }

    pub fn execute(
        self: *Push,
        allocator: std.mem.Allocator,
        root: *Root,
        writer: anytype,
        opts: commands.Options,
    ) !void {
        try root.load();
        _ = allocator;
        _ = opts;

        const item = try self.selection.resolveReportError(root);
        const sl = try root.getStackList();
        const stack = sl.getStackPtr(self.stack) orelse {
            return cli.throwError(
                error.NoSuchStack,
                "Stack '{s}' does not exist",
                .{self.stack},
            );
        };
        try sl.addItemToStack(stack, item, self.message, self.position, time.Time.now());

        const path = item.getPath();

        try root.writeStacks();
        try root.writeChanges();

        try writer.print("Added '{s}' to stack '{s}'\n", .{ path, stack.name });
    }
};

pub const Pop = struct {
    pub const short_help = "Pop from a stack";
    pub const long_help = short_help;
    pub const arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{
        .{
            .arg = "stack",
            .help = "Name of the stack to pop from.",
            .required = true,
            .completion = "{compadd $(nkt completion list --collection stacks)}",
        },
        .{
            .arg = "index",
            .help = "The index of the item to pop from the stack (default: 0).",
            .argtype = usize,
        },
    });

    args: arguments.Parsed,

    pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Pop {
        return .{ .args = try arguments.parseAll(itt) };
    }

    pub fn execute(
        self: *Pop,
        allocator: std.mem.Allocator,
        root: *Root,
        writer: anytype,
        opts: commands.Options,
    ) !void {
        try root.load();
        _ = allocator;
        _ = opts;

        const sl = try root.getStackList();
        const stack = sl.getStackPtr(self.args.stack) orelse {
            return cli.throwError(
                error.NoSuchStack,
                "Stack '{s}' does not exist",
                .{self.args.stack},
            );
        };
        const index = self.args.index orelse 0;
        if (index >= stack.items.len) {
            return cli.throwError(
                error.InvalidItem,
                "Cannot pop item {d} from a stack with length {d}",
                .{ index, stack.items.len },
            );
        }
        const descr = sl.popAt(stack, index).?;

        try root.writeStacks();
        try root.writeChanges();

        try writer.print(
            "Popped item: {s} (from {s} '{s}')\n",
            .{
                descr.name,
                switch (descr.collection) {
                    .CollectionDirectory => "directory",
                    .CollectionJournal => "journal",
                    .CollectionTasklist => "tasklist",
                },
                descr.parent,
            },
        );

        if (stack.items.len > 0) {
            const head = stack.items[0];
            try writer.print(
                "New head is now: {s} (from {s} '{s}')\n\n",
                .{
                    head.name,
                    switch (head.collection) {
                        .CollectionDirectory => "directory",
                        .CollectionJournal => "journal",
                        .CollectionTasklist => "tasklist",
                    },
                    head.parent,
                },
            );
        } else {
            try writer.writeAll("Stack now empty");
        }
        _ = allocator;
        _ = opts;
    }
};

pub const Peek = struct {
    pub const short_help = "Peek at a stack";
    pub const long_help = short_help;
    pub const arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{
        .{
            .arg = "stack",
            .help = "Name of the stack peek at.",
            .required = true,
            .completion = "{compadd $(nkt completion list --collection stacks)}",
        },
    });

    args: arguments.Parsed,

    pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Peek {
        return .{ .args = try arguments.parseAll(itt) };
    }

    pub fn execute(
        self: *Peek,
        allocator: std.mem.Allocator,
        root: *Root,
        writer: anytype,
        opts: commands.Options,
    ) !void {
        try root.load();
        _ = allocator;

        const sl = try root.getStackList();
        const stack = sl.getStackPtr(self.args.stack) orelse {
            return cli.throwError(
                error.NoSuchStack,
                "Stack '{s}' does not exist",
                .{self.args.stack},
            );
        };

        var itt = utils.ReverseIterator(stacks.ItemDescriptor).init(stack.items);
        while (itt.next()) |item| {
            const i = stack.items.len - (itt.index);
            const container_type_name = switch (item.collection) {
                .CollectionDirectory => "directory",
                .CollectionJournal => "journal",
                .CollectionTasklist => "tasklist",
            };
            try writer.print(
                "[{d}] : {s} | ",
                .{
                    i,
                    try item.added.formatDateTime(),
                },
            );

            if (!opts.piped) {
                try colors.CYAN.bold().write(writer, "{s}", .{item.name});

                try colors.DIM.write(
                    writer,
                    " from {s} '{s}'",
                    .{ container_type_name, item.parent },
                );
            } else {
                try writer.print(
                    "{s} from {s} '{s}'",
                    .{ item.name, container_type_name, item.parent },
                );
            }

            try writer.writeAll("\n");
            if (item.message.len > 0) {
                try writer.print(
                    " └ {s}\n",
                    .{item.message},
                );
            }
            try writer.writeAll("\n");
        }
    }
};
