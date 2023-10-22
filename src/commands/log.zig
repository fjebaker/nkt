const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../NewState.zig");

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

pub fn init(itt: *cli.ArgIterator) !Self {
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
    self.journal = self.journal orelse "diary";
    self.text = self.text orelse return cli.CLIErrors.TooFewArguments;
    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const journal_name = self.journal.?;

    var journal = state.getJournal(self.journal.?) orelse
        return cli.SelectionError.NoSuchJournal;

    if (std.mem.eql(u8, journal_name, "diary")) {
        const today_string = try utils.formatDateBuf(utils.Date.now());
        var entry = journal.getEntryByName(&today_string) orelse
            try journal.newChild(&today_string);

        try entry.add(self.text.?);

        try out_writer.print(
            "Written text to '{s} : {s}'\n",
            .{ journal_name, entry.item.name },
        );
    } else {
        // todo
        unreachable;
    }
}
