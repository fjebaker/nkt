const std = @import("std");

const cli = @import("../cli.zig");
const utils = @import("../utils.zig");
const colors = @import("../colors.zig");

const State = @import("../State.zig");
const BlockPrinter = @import("../BlockPrinter.zig");
const Entry = @import("../Topology.zig").Entry;

const Self = @This();

pub const alias = [_][]const u8{"chain"};

pub const help = "Interact and print chains.";

pretty: ?bool = null,
num_days: usize = 30,
chain_name: ?[]const u8 = null,

pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {
    var self: Self = .{};

    while (try itt.next()) |arg| {
        if (arg.flag) {
            if (arg.is('n', "num")) {
                self.num_days = try arg.as(usize);
            } else if (arg.is(null, "no-pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = false;
            } else if (arg.is(null, "pretty")) {
                if (self.pretty != null) return cli.CLIErrors.InvalidFlag;
                self.pretty = true;
            } else {
                return cli.CLIErrors.UnknownFlag;
            }
        } else {
            if (self.chain_name != null) return cli.CLIErrors.TooManyArguments;
            self.chain_name = arg.string;
        }
    }

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
    const day_end = utils.endOfDay(today);

    // populate day slots
    var days = try allocator.alloc(Day, days_hence);
    for (days, 0..) |*day, i| {
        day.* = Day.init(day_end.shiftDays(-@as(i32, @intCast(i))));
    }

    var itt = utils.ReverseIterator(u64).init(chain.completed);
    while (itt.next()) |item| {
        const date = utils.dateFromMs(item);
        const delta = day_end.sub(date);

        if (delta.years == 0 and delta.days < days.len) {
            const index: usize = @intCast(delta.days);
            days[index].completed = true;
        } else break;
    }

    std.mem.reverse(Day, days);
    return days;
}

const COMPLETED_FORMAT = colors.GREEN.fixed();
const WEEKEND_FORMAT = colors.YELLOW.fixed();

pub fn printHeadings(writer: anytype, padding: usize, days: []const Day, pretty: bool) !void {
    try writer.writeByteNTimes(' ', padding + 3);
    for (days) |day| {
        const repr: u8 = switch (day.weekday) {
            .Monday => 'M',
            .Tuesday, .Thursday => 'T',
            .Wednesday => 'W',
            .Friday => 'F',
            .Saturday, .Sunday => 'S',
        };

        if (repr == 'S' and pretty)
            try WEEKEND_FORMAT.writeOpen(writer);

        try writer.writeByte(repr);

        if (repr == 'S' and pretty)
            try WEEKEND_FORMAT.writeClose(writer);

        if (day.weekday == .Sunday) try writer.writeByte(' ');
    }
    try writer.writeAll("\n");
}

fn consecutiveDays(days: []const Day) usize {
    var tally: usize = 0;
    for (0..days.len) |i| {
        const index = days.len - 1 - i;
        const day = days[index];
        if (day.completed) {
            tally += 1;
        } else break;
    }
    return tally;
}

pub fn printChain(
    writer: anytype,
    padding: usize,
    name: []const u8,
    days: []const Day,
    pretty: bool,
) !void {
    const pad = padding - name.len;

    try writer.writeAll(" ");
    try writer.writeByteNTimes(' ', pad);
    try writer.writeAll(name);
    try writer.writeAll("  ");

    for (days, 0..) |day, i| {
        if (day.completed) {
            if (pretty) try COMPLETED_FORMAT.writeOpen(writer);
            try writer.writeAll("█");
            if (pretty) try COMPLETED_FORMAT.writeClose(writer);
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

    // write the current consecutive streak
    const count = consecutiveDays(days);
    if (count > 0) {
        try writer.print("  {d: <5}", .{count});
    }

    try writer.writeAll("\n");
}

pub fn run(
    self: *Self,
    state: *State,
    out_writer: anytype,
) !void {
    const today = utils.dateFromMs(utils.now());

    if (self.chain_name) |name| {
        const chain = try state.getChainByName(name) orelse
            return cli.SelectionError.NoSuchCollection;

        var items = try prepareChain(state.allocator, today, self.num_days, chain.*);
        defer state.allocator.free(items);

        const padding = calculatePadding(&[_]State.Chain{chain.*});

        try out_writer.writeAll("\n");
        try printHeadings(out_writer, padding, items, self.pretty.?);
        try printChain(out_writer, padding, chain.name, items, self.pretty.?);
        try out_writer.writeAll("\n");
    } else {
        const chains = try state.getChains();

        const padding = calculatePadding(chains);

        var arena = std.heap.ArenaAllocator.init(state.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const first_items = try prepareChain(alloc, today, self.num_days, chains[0]);

        try out_writer.writeAll("\n");
        try printHeadings(out_writer, padding, first_items, self.pretty.?);
        for (chains) |chain| {
            var items = try prepareChain(alloc, today, self.num_days, chain);
            try printChain(out_writer, padding, chain.name, items, self.pretty.?);
        }
        try out_writer.writeAll("\n");
    }
}

fn calculatePadding(chains: []const State.Chain) usize {
    var padding: usize = 0;
    for (chains) |chain| {
        padding = @max(padding, chain.name.len);
    }
    return padding;
}
