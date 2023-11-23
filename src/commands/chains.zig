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
    const today_shifted = today.shiftDays(1 - @as(i32, @intCast(days_hence)));
    // shift the oldest to start at midnight
    const oldest = today_shifted.shiftSeconds(-today_shifted.time.totalSeconds());

    // +1 to include today
    var days = try allocator.alloc(Day, days_hence);
    for (days, 0..) |*day, i| {
        day.* = Day.init(oldest.shiftDays(@as(i32, @intCast(i)) + 1));
    }

    var itt = utils.ReverseIterator(u64).init(chain.completed);
    while (itt.next()) |item| {
        const date = utils.dateFromMs(item);
        const delta = date.sub(oldest);
        // see which day this slots into
        if (delta.years == 0 and delta.days >= 0 and delta.days < days.len) {
            days[@intCast(delta.days)].completed = true;
        } else break;
    }

    return days;
}

pub fn printHeadings(writer: anytype, padding: usize, days: []const Day, pretty: bool) !void {
    comptime var cham = Chameleon.init(.Auto);
    const weekend_color = cham.yellow();

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
            try writer.writeAll(weekend_color.open);

        try writer.writeByte(repr);

        if (repr == 'S' and pretty)
            try writer.writeAll(weekend_color.close);

        if (day.weekday == .Sunday) try writer.writeByte(' ');
    }
    try writer.writeAll("\n");
}

pub fn printChain(
    writer: anytype,
    padding: usize,
    name: []const u8,
    days: []const Day,
    pretty: bool,
) !void {
    comptime var cham = Chameleon.init(.Auto);
    const completed_color = cham.greenBright();

    const pad = padding - name.len;

    try writer.writeAll(" ");
    try writer.writeByteNTimes(' ', pad);
    try writer.writeAll(name);
    try writer.writeAll("  ");

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

    if (self.chain_name) |name| {
        const chain = try state.getChainByName(name) orelse
            return cli.SelectionError.NoSuchCollection;

        const items = try prepareChain(state.allocator, today, self.num_days, chain.*);
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
            const items = try prepareChain(alloc, today, self.num_days, chain);
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
