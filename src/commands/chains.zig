const std = @import("std");

const Chameleon = @import("chameleon").Chameleon;

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const BlockPrinter = @import("../BlockPrinter.zig");
const Entry = @import("../collections/Topology.zig").Entry;

const Self = @This();

pub const alias = [_][]const u8{"chain"};

pub const help = "Interact and print chains.";

pretty: ?bool = null,
num_days: usize = 30,
chain_name: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    var self: Self = .{};

    const arg = (try itt.nextPositional()) orelse
        return cli.CLIErrors.TooFewArguments;

    self.chain_name = arg.string;

    self.pretty = self.pretty orelse !opts.piped;
    return self;
}

const Chain = State.Chain;
const Weekday = utils.time.datetime.Weekday;

const Day = struct {
    weekday: Weekday,
    completed: bool,

    pub fn init(date: utils.Date) Day {
        const weekday = date.date.dayOfWeek();
        return .{
            .weekday = weekday,
            .completed = false,
        };
    }
};

fn prepareChain(
    allocator: std.mem.Allocator,
    today: utils.Date,
    days_hence: usize,
    chain: Chain,
) ![]Day {
    const oldest = today.shiftDays(-@as(i32, @intCast(days_hence)));

    // +1 to include today
    var days = try allocator.alloc(Day, days_hence + 1);
    for (days, 0..) |*day, i| {
        day.* = Day.init(oldest.shiftDays(@intCast(i)));
    }

    var itt = utils.ReverseIterator(u64).init(chain.completed);
    while (itt.next()) |item| {
        const date = utils.dateFromMs(item);
        const delta = date.sub(oldest);
        if (delta.years == 0 and delta.days >= 0 and delta.days < days.len) {
            days[@intCast(delta.days)].completed = true;
        } else break;
    }

    return days;
}

pub fn printHeadings(writer: anytype, days: []const Day, pretty: bool) !void {
    comptime var cham = Chameleon.init(.Auto);
    const weekend_color = cham.dim();

    try writer.writeByteNTimes(' ', 15);
    for (days) |day| {
        const repr: u8 = switch (day.weekday) {
            .Monday => 'M',
            .Tuesday, .Thursday => 'T',
            .Wednesday => 'W',
            .Friday => 'F',
            .Saturday, .Sunday => 'S',
        };
        if (repr == 'S' and pretty)
            try writer.writeAll(weekend_color.open);

        try writer.writeByte(repr);

        if (repr == 'S' and pretty)
            try writer.writeAll(weekend_color.close);

        if (day.weekday == .Sunday) try writer.writeByte(' ');
    }
    try writer.writeAll("\n");
}

pub fn printChain(writer: anytype, name: []const u8, days: []const Day, pretty: bool) !void {
    comptime var cham = Chameleon.init(.Auto);
    const completed_color = cham.greenBright();

    try writer.print("{s: <12} : ", .{name});
    for (days, 0..) |day, i| {
        if (day.completed) {
            if (pretty) try writer.writeAll(completed_color.open);
            try writer.writeAll("█");
            if (pretty) try writer.writeAll(completed_color.close);
        } else {
            if (i == days.len - 1) {
                // special character for today if not completed
                try writer.writeAll("-");
            } else {
                try writer.writeAll("░");
            }
        }
        if (day.weekday == .Sunday) try writer.writeByte(' ');
    }
    try writer.writeAll("\n");
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const today = utils.dateFromMs(utils.now());

    const chain = try state.getChainByName(self.chain_name.?) orelse
        return cli.SelectionError.NoSuchCollection;

    var items = try prepareChain(state.allocator, today, self.num_days, chain.*);
    defer state.allocator.free(items);

    try out_writer.writeAll("\n");
    try printHeadings(out_writer, items, self.pretty.?);
    try printChain(out_writer, self.chain_name.?, items, self.pretty.?);
    try out_writer.writeAll("\n");
}
