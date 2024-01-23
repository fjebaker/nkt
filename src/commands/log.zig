const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const tags = @import("../tags.zig");

const State = @import("../State.zig");

const Self = @This();

pub const help = "Quickly add a note to a journal from the command line";

pub const extended_help =
    \\Quickly add a note to a given journal from the command line.
    \\
    \\  nkt log
    \\     [-j/--journal name]   name of journal to write to (default: diary)
    \\     <text>                text to log
    \\     [tag1,tag2,...]       optional tags for the entry
    \\
;

text: ?[]const u8 = null,
tags: std.ArrayList([]const u8),
journal: ?[]const u8 = null,

pub fn init(alloc: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{ .tags = std.ArrayList([]const u8).init(alloc) };

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('j', "journal")) {
                if (self.journal != null) return cli.CLIErrors.DuplicateFlag;
                self.journal = (try itt.getValue()).string;
            }
        } else {
            if (self.text != null) {
                if (arg.string[0] == '@') {
                    try self.tags.append(arg.string[1..]);
                } else return cli.CLIErrors.BadArgument;
            } else {
                self.text = arg.string;
            }
        }
    }
    self.text = self.text orelse return cli.CLIErrors.TooFewArguments;
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const journal_name: []const u8 = self.journal orelse "diary";

    var journal = state.getJournal(journal_name) orelse
        return cli.SelectionError.NoSuchCollection;

    const today_string = try utils.formatDateBuf(utils.Date.now());
    var entry = journal.get(&today_string) orelse
        try journal.Journal.newDay(&today_string);

    var contexts = try tags.parseContexts(state.allocator, self.text.?);
    defer contexts.deinit();

    const allowed_tags = state.getTagInfo();

    const ts = try contexts.getTags(allowed_tags);

    var ptr_to_entry = try entry.Day.add(self.text.?);
    try tags.addTags(
        journal.Journal.content.allocator(),
        &ptr_to_entry.tags,
        ts,
    );

    if (self.tags.items.len > 0) {
        const appended_tags = try tags.makeTagList(
            state.allocator,
            self.tags.items,
            allowed_tags,
        );
        defer state.allocator.free(appended_tags);
        try tags.addTags(
            journal.Journal.content.allocator(),
            &ptr_to_entry.tags,
            appended_tags,
        );
    }

    try state.writeChanges();
    try out_writer.print(
        "Written text to '{s}' in journal '{s}'\n",
        .{ entry.getName(), journal_name },
    );
}
