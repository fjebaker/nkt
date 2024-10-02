const std = @import("std");
const cli = @import("../cli.zig");
const ttags = @import("../topology/tags.zig");
const utils = @import("../utils.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");
const Editor = @import("../Editor.zig");
const BlockPrinter = @import("../printers.zig").BlockPrinter;

const Self = @This();

pub const short_help = "Quickly log something to a journal from the command line";

pub const long_help =
    \\Add an entry to a journal by logging a new line. Entries contrast from diary
    \\notes in that they are single, short lines or items, a literal
    \\log file of your day. For longer form daily notes, use the 'edit' command.
    \\Entries support the standard infix tagging (i.e. @tag).
    \\
    \\If writing in the editor, everything will be truncated onto one line
    \\except for @tags. Tags on a line without any other text will be treated as
    \\appended on the CLI.
;

pub const arguments = cli.Arguments(&.{
    .{
        .arg = "text",
        .help = "The text to log for the entry. If blank will open editor for editing notes.",
    },
    .{
        .arg = "-j/--journal name",
        .help = "The name of the journal to add the entry to (else uses default journal).",
    },
    .{
        .arg = "@tag1 [@tag2 ...]",
        .help = "Additional tags to add.",
        .parse = false,
    },
});

tags: []const []const u8,
args: arguments.Parsed,

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var tag_list = std.ArrayList([]const u8).init(allocator);
    defer tag_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) try itt.throwUnknownFlag();
            // tag parsing
            const tag_name = ttags.getTagString(arg.string) catch |err| {
                return cli.throwError(err, "{s}", .{arg.string});
            };

            if (tag_name) |name| {
                try tag_list.append(name);
            } else {
                try itt.throwBadArgument("tag format: tags must begin with `@`");
            }
        }
    }

    const args = try parser.getParsed();
    return .{
        .tags = try tag_list.toOwnedSlice(),
        .args = args,
    };
}

pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    opts: commands.Options,
) !void {
    // load the topology
    try root.load();

    const journal_name = self.args.journal orelse
        root.info.default_journal;

    var j = (try root.getJournal(journal_name)) orelse {
        return cli.throwError(
            Root.Error.NoSuchCollection,
            "Journal '{s}' does not exist",
            .{journal_name},
        );
    };

    if (self.args.text) |t| {
        try addEntryToJournal(allocator, t, self.tags, root, &j, writer);
    } else {
        const im_writer = opts.unbuffered_writer;
        var result = try fromEditor(allocator);
        defer result.deinit();

        if (result.text.len == 0) {
            try im_writer.writeAll("No text given. Nothing written to journal.\n");
            return;
        }

        const tdl = try root.getTagDescriptorList();
        var bprinter = BlockPrinter.init(allocator, .{
            .tag_descriptors = tdl.tags,
            .pretty = !opts.piped,
        });
        defer bprinter.deinit();

        try bprinter.addBlock("Entry parsed:\n\n", .{});
        try bprinter.addFormatted(.Item, "{s}\n-- ", .{result.text}, .{});
        for (result.tags) |tag| {
            try bprinter.addFormatted(.Item, "{s} ", .{tag}, .{});
        }
        try bprinter.drain(im_writer);

        try im_writer.writeByte('\n');

        if (try utils.promptYes(
            allocator,
            im_writer,
            "Add entry to journal '{s}'?",
            .{j.descriptor.name},
        )) {
            try addEntryToJournal(
                allocator,
                result.text,
                result.tags,
                root,
                &j,
                writer,
            );
        }
    }
}

const LogInput = struct {
    arena: std.heap.ArenaAllocator,
    tags: []const []const u8,
    text: []const u8,

    pub fn deinit(self: *LogInput) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn onlyTags(content: []const u8) bool {
    var word_itt = std.mem.tokenizeAny(u8, content, " ");
    while (word_itt.next()) |tkn| {
        if (tkn[0] != '@') return false;
    }
    return true;
}

fn fromEditor(allocator: std.mem.Allocator) !LogInput {
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const input = try editor.editTemporaryContent(
        alloc,
        "",
    );

    var tag_list = std.ArrayList([]const u8).init(alloc);
    defer tag_list.deinit();

    var text_list = std.ArrayList(u8).init(alloc);
    defer text_list.deinit();

    var itt = std.mem.tokenizeAny(u8, input, "\n");
    var on_tags: bool = false;
    while (itt.next()) |line| {
        const content = std.mem.trim(u8, line, " ");
        if (content[0] == '@' and onlyTags(content)) {
            on_tags = true;
            var word_itt = std.mem.tokenizeAny(u8, content, " ");
            while (word_itt.next()) |tkn| {
                try tag_list.append(tkn);
            }
            break;
        }

        if (on_tags) {
            return error.InvalidTag;
        }
        try text_list.appendSlice(content);
        try text_list.append(' ');
    }

    return .{
        .arena = arena,
        .tags = try tag_list.toOwnedSlice(),
        .text = try text_list.toOwnedSlice(),
    };
}

fn addEntryToJournal(
    allocator: std.mem.Allocator,
    text: []const u8,
    e_tags: []const []const u8,
    root: *Root,
    j: *Root.Journal,
    writer: anytype,
) !void {
    root.markModified(j.descriptor, .CollectionJournal);

    const entry_tags = try utils.parseAndAssertValidTags(
        allocator,
        root,
        text,
        e_tags,
    );
    defer allocator.free(entry_tags);
    const day = try j.addNewEntryFromText(text, entry_tags);

    try root.writeChanges();
    try j.writeDays();

    try writer.print(
        "Written entry {s} in journal '{s}'\n",
        .{ try day.modified.formatDateTime(), j.descriptor.name },
    );
}
