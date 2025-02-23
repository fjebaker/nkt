const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");

const commands = @import("../commands.zig");
const Commands = commands.Commands;
const Root = @import("../topology/Root.zig");

const Self = @This();

const SelectArgs = selections.selectHelp(
    "item",
    "Completion for an item selection.",
    .{ .required = false },
);

const SelectArguments = cli.Arguments(SelectArgs);
const ListArguments = cli.Arguments(
    &.{
        .{
            .arg = "--collection type",
            .help = "List the names of all collection names of a given type.",
        },
        .{
            .arg = "--all-collections",
            .help = "List the names of all collection of all types.",
        },
        .{
            .arg = "--tags",
            .help = "List the names of all tags (with the `@` prefix).",
        },
    },
);

pub const Arguments = cli.Commands(union(enum) {
    list: ListArguments,
    item: SelectArguments,
});

pub const short_help = "Shell completion helper";
pub const long_help = short_help;

args: ?Arguments.Parsed,
unused: []const []const u8 = &.{},

const StringList = std.ArrayList([]const u8);

pub fn fromArgs(alloc: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    if (itt.argCount() > 2) {
        var list = StringList.init(alloc);
        defer list.deinit();

        const Ctx = struct {
            l: *StringList,
            fn handleArg(self: *@This(), _: *const Arguments, arg: cli.Arg) anyerror!void {
                try self.l.append(arg.string);
            }
        };

        var ctx: Ctx = .{ .l = &list };
        var parser = Arguments.init(itt, .{ .forgiving = true });
        const parsed = try parser.parseAllCtx(&ctx, .{ .unhandled_arg = Ctx.handleArg });

        return .{ .args = parsed, .unused = try list.toOwnedSlice() };
    } else {
        return .{ .args = null };
    }
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    if (self.args != null) {
        self.executeInternal(allocator, root, writer, opts) catch |err| {
            // for debug builds, actually give the error
            if (@import("builtin").mode == .Debug) return err;
            std.log.default.debug("completion error: {any}", .{err});
        };
    } else {
        try writeTemplate(allocator, writer);
    }
}

fn executeInternal(
    self: Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    try root.load();
    _ = opts;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    switch (self.args.?) {
        .list => |args| {
            // use a hash map to avoid duplicate names
            var names = std.StringArrayHashMap(void).init(allocator);
            defer names.deinit();

            const collection = args.collection orelse "";
            const all = args.@"all-collections";

            if (all or std.mem.eql(u8, collection, "journal")) {
                for (root.info.journals) |c| {
                    try names.put(c.name, {});
                }
            }
            if (all or std.mem.eql(u8, collection, "directory")) {
                for (root.info.directories) |c| {
                    try names.put(c.name, {});
                }
            }
            if (all or std.mem.eql(u8, collection, "tasklist")) {
                for (root.info.tasklists) |c| {
                    try names.put(c.name, {});
                }
            }
            if (std.mem.eql(u8, collection, "stacks")) {
                const sl = try root.getStackList();
                for (sl.stacks) |s| {
                    try names.put(s.name, {});
                }
            }
            if (std.mem.eql(u8, collection, "chains")) {
                const chainlist = try root.getChainList();
                for (chainlist.chains) |c| {
                    try names.put(c.name, {});
                    if (c.alias) |alias| {
                        try names.put(alias, {});
                    }
                }
            }

            if (args.tags) {
                const tl = try root.getTagDescriptorList();
                for (tl.tags) |t| {
                    const t_name = try std.fmt.allocPrint(alloc, "@{s}", .{t.name});
                    try names.put(t_name, {});
                }
            }

            if (names.count() == 0) {
                return cli.throwError(
                    error.UnknownSelection,
                    "Invalid completion collection '{s}'",
                    .{collection},
                );
            }

            for (names.keys()) |key| {
                try writer.writeAll(key);
                try writer.writeAll(" ");
            }
        },
        .item => |args| {
            const selection = try selections.fromArgsForgiving(
                SelectArguments.Parsed,
                args.item,
                args,
            );

            if (selection.collection_type) |ctype| {
                switch (ctype) {
                    .CollectionDirectory => try listNotesInDirectory(
                        writer,
                        root,
                        selection.collection_name,
                        allocator,
                        null,
                    ),
                    .CollectionJournal => {
                        // are we generating completion for the times?
                        if (isSelectingTime(self.unused, selection)) {
                            try listTimesFor(writer, root, selection, allocator);
                            return;
                        }

                        // if (selection.selector) |_| {};
                    },
                    else => {},
                }
            } else if (selection.collection_name != null) {
                const col = (try selection.resolveOrNull(root)) orelse return;
                switch (col.Collection) {
                    .directory => {
                        try listNotesInDirectory(
                            writer,
                            root,
                            selection.collection_name,
                            allocator,
                            selection.collection_name,
                        );
                    },
                    // TODO: all the other collection types
                    else => {},
                }
            } else {
                if (isSelectingTime(self.unused, selection)) {
                    try listTimesFor(writer, root, selection, allocator);
                    return;
                }
                // TODO: if it's date-like, list from diary
                try listNotesInDirectory(writer, root, null, allocator, null);
            }
        },
    }
}

fn isSelectingTime(
    unused: []const []const u8,
    selection: selections.Selection,
) bool {
    return (selection.modifiers.time != null or
        utils.contains([]const u8, unused, "time"));
}

fn listTimesFor(
    writer: anytype,
    root: *Root,
    selection: selections.Selection,
    _: std.mem.Allocator,
) !void {
    var s = selection;
    const tstring = s.modifiers.time;
    s.modifiers.time = null;

    std.log.default.debug("Listing times for: '{s}'", .{tstring orelse ""});

    var item = try s.resolveOrNull(root);

    if (item) |*day_collection| {
        var day = &day_collection.Day;
        const entries = try day.journal.getEntries(day.day);
        for (entries) |entry| {
            const etime = try entry.created.formatTime();
            if (tstring) |t| {
                if (std.mem.startsWith(u8, &etime, t)) {
                    try writer.print("{s} ", .{etime});
                }
            } else {
                try writer.print("{s} ", .{etime});
            }
        }
    }
}

fn listNotesInDirectory(
    writer: anytype,
    root: *Root,
    name: ?[]const u8,
    allocator: std.mem.Allocator,
    prefix: ?[]const u8,
) !void {
    _ = allocator;
    const dir_name = name orelse root.info.default_directory;
    const dir = (try root.getDirectory(dir_name)) orelse return;

    const dir_info = dir.getInfo();

    for (dir_info.notes) |note| {
        if (prefix) |p| {
            try writer.print("{s}:{s} ", .{ p, note.name });
        } else {
            try writer.print("{s} ", .{note.name});
        }
    }
}

pub fn writeTemplate(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("#compdef _nkt nkt\n\n");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    var case_switches = std.ArrayList(u8).init(alloc);
    defer case_switches.deinit();

    var switch_writer = case_switches.writer();

    var all_commands = std.ArrayList(u8).init(alloc);
    defer all_commands.deinit();

    var all_writer = all_commands.writer();

    const info = @typeInfo(Commands).@"union";
    inline for (info.fields) |field| {
        const name = field.name;
        const descr = @field(field.type, "short_help");
        const has_arguments = @hasDecl(field.type, "Arguments");

        const name_or_alias = try nameOrAlias(alloc, field, '|');
        defer alloc.free(name_or_alias);

        if (has_arguments) {
            const args = @field(field.type, "Arguments");

            const cmpl = try args.generateCompletion(alloc, .{ .function_name = name });
            defer alloc.free(cmpl);
            try writer.writeAll(cmpl);

            try switch_writer.print(
                \\    {s})
                \\        _arguments_{s}
                \\    ;;
                \\
            , .{ name_or_alias, name });
        }

        const escp_descr = try std.mem.replaceOwned(u8, alloc, descr, "'", "'\\''");
        try all_writer.print("        '{s}:{s}'\n", .{ name, escp_descr });
    }

    try writer.print(ZSH_TEMPLATE, .{ all_commands.items, case_switches.items });
}

fn nameOrAlias(alloc: std.mem.Allocator, field: std.builtin.Type.UnionField, sep: u8) ![]const u8 {
    const name = field.name;
    if (!@hasDecl(field.type, "alias")) {
        return try alloc.dupe(u8, name);
    } else {
        var list = std.ArrayList(u8).init(alloc);

        try list.writer().writeAll(name);
        for (@field(field.type, "alias")) |a| {
            try list.writer().print("{c}{s}", .{ sep, a });
        }
        return list.toOwnedSlice();
    }
}

const ZSH_TEMPLATE =
    \\_subcommands() {{
    \\    local -a commands
    \\    commands=(
    \\{s}        )
    \\    _describe 'command' commands
    \\}}
    \\
    \\local line state
    \\
    \\_arguments \
    \\    '1:command:_subcommands' \
    \\    '*::arg:->args'
    \\
    \\case $line[1] in
    \\{s}
    \\esac
    \\
;
