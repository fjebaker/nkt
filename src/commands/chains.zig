const std = @import("std");
const cli = @import("../cli.zig");
const tags = @import("../topology/tags.zig");
const time = @import("../topology/time.zig");
const utils = @import("../utils.zig");
const selections = @import("../selections.zig");
const colors = @import("../colors.zig");

const commands = @import("../commands.zig");
const Root = @import("../topology/Root.zig");

const BlockPrinter = @import("../printers.zig").BlockPrinter;

const chains = @import("../topology/chains.zig");

const Chain = chains.Chain;
const Weekday = time.Weekday;

const COMPLETED_FORMAT = colors.GREEN;
const WEEKEND_FORMAT = colors.YELLOW;

const Self = @This();

pub const alias = [_][]const u8{"chain"};

pub const short_help = "View and interact with habitual chains.";
pub const long_help = short_help;

pub const Arguments = cli.Arguments(&[_]cli.ArgumentDescriptor{
    .{
        .arg = "--days num",
        .help = "Number of days to display",
        .argtype = usize,
        .default = "30",
    },
});

num_days: usize,

pub fn fromArgs(_: std.mem.Allocator, itt: *cli.ArgIterator) !Self {
    const args = try Arguments.initParseAll(itt, .{});
    const num_days = args.days;
    return .{ .num_days = num_days };
}
pub fn execute(
    self: *Self,
    allocator: std.mem.Allocator,
    root: *Root,
    writer: anytype,
    _: commands.Options,
) !void {
    try root.load();
    const today = time.Time.now().toDate();

    const all_chains = try root.getChains();
    if (all_chains.len == 0) {
        try writer.writeAll(" -- No chains -- \n");
        return;
    }

    const padding = calculatePadding(all_chains);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const first_items = try prepareChain(
        alloc,
        today,
        self.num_days,
        all_chains[0],
    );

    try writer.writeAll("\n");
    // TODO: fix pretty printing toggles
    try printHeadings(writer, padding, first_items, true);
    for (all_chains) |chain| {
        const items = try prepareChain(
            alloc,
            today,
            self.num_days,
            chain,
        );
        try printChain(writer, padding, chain.name, items, true);
    }
    try writer.writeAll("\n");
}

const Day = struct {
    weekday: Weekday,
    completed: bool,

    pub fn init(date: time.Date) Day {
        const weekday = date.date.dayOfWeek();
        return .{
            .weekday = weekday,
            .completed = false,
        };
    }
};

fn prepareChain(
    allocator: std.mem.Allocator,
    today: time.Date,
    days_hence: usize,
    chain: Chain,
) ![]Day {
    // populate day slots
    var days = try allocator.alloc(Day, days_hence);
    for (days, 0..) |*day, i| {
        day.* = Day.init(today.shiftDays(-@as(i32, @intCast(i))));
    }

    var itt = utils.ReverseIterator(time.Time).init(chain.completed);
    while (itt.next()) |item| {
        var date = item.toDate();
        // for the purposes of chains, use the same timezones
        date.zone = today.zone;
        date.time = today.time;
        const delta = today.sub(date);

        if (delta.years == 0 and delta.days < days.len) {
            const index: usize = @intCast(delta.days);
            days[index].completed = true;
        } else break;
    }

    std.mem.reverse(Day, days);
    return days;
}

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

fn calculatePadding(all_chains: []const chains.Chain) usize {
    var padding: usize = 0;
    for (all_chains) |chain| {
        padding = @max(padding, chain.name.len);
    }
    return padding;
}
