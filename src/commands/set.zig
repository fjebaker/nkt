const std = @import("std");
const cli = @import("../cli.zig");
const utils = @import("../utils.zig");

const State = @import("../State.zig");
const TaskPrinter = @import("../TaskPrinter.zig");

const Self = @This();

pub const help = "Modify attributes of entries, notes, or tasks.";


pub fn init(_: std.mem.Allocator, itt: *cli.ArgIterator, opts: cli.Options) !Self {

}
