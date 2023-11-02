const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");

const Self = @This();

pub const help = "Quickly add a note to a journal from the command line";

pub const extended_help =
    \\Quickly add a note to a given journal from the command line.
    \\
    \\  nkt log
    \\     <text>                text to log
    \\     [-j/--journal name]   name of journal to write to (default: diary)
    \\
;

text: ?[]const u8 = null,
journal: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, _: cli.Options) !Self {
    var self: Self = .{};

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('j', "journal")) {
                if (self.journal != null) return cli.CLIErrors.DuplicateFlag;
                self.journal = (try itt.getValue()).string;
            }
        } else {
            if (self.text != null) return cli.CLIErrors.TooManyArguments;
            self.text = arg.string;
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

    try entry.Day.add(self.text.?);

    try state.writeChanges();
    try out_writer.print(
        "Written text to '{s}' in journal '{s}'\n",
        .{ entry.getName(), journal_name },
    );
}
