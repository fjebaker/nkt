const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const Self = @This();

pub const short_help = "Quickly log something to a journal from the command line";

pub const long_help =
    \\Add an entry to a journal by logging a new line. Entries contrast from diary
    \\notes in that they are single, short lines or items, a literal
    \\log file of your day. For longer form daily notes, use the 'edit' command.
    \\Entries support the standard infix tagging (i.e. @tag).
;

pub const arguments = cli.ArgumentsHelp(&.{
    .{
        .arg = "text",
        .help = "The text to log for the entry.",
        .required = true,
    },
    .{
        .arg = "-j/--journal name",
        .help = "The name of the journal to add the entry to (else uses default journal).",
    },
    .{
        .arg = "@tag1,@tag2,...",
        .help = "Additional tags to add.",
        .parse = false,
    },
}, .{});

tags: []const []const u8,
args: arguments.ParsedArguments,

pub fn fromArgs(allocator: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    var parser = arguments.init(itt);

    var tag_list = std.ArrayList([]const u8).init(allocator);
    defer tag_list.deinit();

    while (try itt.next()) |arg| {
        if (!try parser.parseArg(arg)) {
            if (arg.flag) try itt.throwUnknownFlag();
            // tag parsing
            const tag_name = tags.isTagString(arg.string) catch |err| {
                try cli.throwError(err, "{s}", .{arg.string});
                unreachable;
            };

            if (tag_name) |name| {
                try tag_list.append(name);
            } else {
                try itt.throwBadArgument("Bad tag format");
            }
        }
    }

    return .{
        .tags = try tag_list.toOwnedSlice(),
        .args = parser.parsed,
    };
}

pub fn execute(
    _: *Self,
    _: std.mem.Allocator,
    _: *Root,
    _: anytype,
    _: commands.Options,
) !void {
    // const journal_name = self.args.journal orelse
    //     root.info.default_journal;

    // root.getJournal
}

// pub fn run(
//     self: *Self,
//     state: *State,
//     out_writer: anytype,
// ) !void {
//     const journal_name: []const u8 = self.journal orelse "diary";

//     var journal = state.getJournal(journal_name) orelse
//         return cli.SelectionError.NoSuchCollection;

//     const today_string = try utils.formatDateBuf(utils.Date.now());
//     var entry = journal.get(&today_string) orelse
//         try journal.Journal.newDay(&today_string);

//     var contexts = try tags.parseContexts(state.allocator, self.text.?);
//     defer contexts.deinit();

//     const allowed_tags = state.getTagInfo();

//     const ts = try contexts.getTags(allowed_tags);

//     var ptr_to_entry = try entry.Day.add(self.text.?);
//     try tags.addTags(
//         journal.Journal.content.allocator(),
//         &ptr_to_entry.tags,
//         ts,
//     );

//     if (self.tags.items.len > 0) {
//         const appended_tags = try tags.makeTagList(
//             state.allocator,
//             self.tags.items,
//             allowed_tags,
//         );
//         defer state.allocator.free(appended_tags);
//         try tags.addTags(
//             journal.Journal.content.allocator(),
//             &ptr_to_entry.tags,
//             appended_tags,
//         );
//     }

//     try state.writeChanges();
//     try out_writer.print(
//         "Written text to '{s}' in journal '{s}'\n",
//         .{ entry.getName(), journal_name },
//     );
// }
