const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const tags = @import("../tags.zig");

const State = @import("../State.zig");

const Self = @This();

pub const ListError = error{CannotListJournal};

pub const alias = [_][]const u8{"sum"};

pub const help = "Print various summaries.";
pub const extended_help =
    \\Print various summaries.
    \\  nkt summary
    \\     <date-like>           default: today
    \\
;

date: ?utils.Date = null,
pretty: ?bool = true,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    var self: Self = .{};

    var what: ?[]const u8 = null;

    while (try itt.next()) |arg| {
        if (arg.flag) {
            return cli.CLIErrors.UnknownFlag;
        } else {
            if (what == null) {
                what = arg.string;
            } else return cli.CLIErrors.TooManyArguments;
        }
    }

    // don't pretty format by default if not tty
    self.pretty = self.pretty orelse !opts.piped;
    self.date = try cli.selections.parseDateTimeLike(
        what orelse "today",
    );

    return self;
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    _ = state;
    std.debug.print(">> {any}\n", .{self.date});
    _ = out_writer;
}
