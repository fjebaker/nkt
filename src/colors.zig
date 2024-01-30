const std = @import("std");
const farbe = @import("farbe");

pub const Farbe = farbe.Farbe;
pub const ComptimeFarbe = farbe.ComptimeFarbe;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toFarbe(c: Color, allocator: std.mem.Allocator) !Farbe {
        var clr = Farbe.init(allocator);
        errdefer clr.deinit();
        try clr.fgRgb(c.r, c.g, c.b);
        return clr;
    }

    pub fn toBackgroundFarbe(c: Color, allocator: std.mem.Allocator) !Farbe {
        var clr = Farbe.init(allocator);
        errdefer clr.deinit();
        try clr.bgRgb(c.r, c.g, c.b);
        return clr;
    }
};

fn colorToFarbe(color: Color) ComptimeFarbe {
    return ComptimeFarbe.init().fgRgb(color.r, color.g, color.b);
}

pub const C_BLUE = Color{ .r = 0, .g = 0, .b = 255 };
pub const C_CYAN = Color{ .r = 0, .g = 255, .b = 255 };
pub const C_GREEN = Color{ .r = 0, .g = 255, .b = 0 };
pub const C_PURPLE = Color{ .r = 255, .g = 0, .b = 255 };
pub const C_RED = Color{ .r = 255, .g = 0, .b = 0 };
pub const C_YELLOW = Color{ .r = 200, .g = 200, .b = 0 };

pub const BLUE = colorToFarbe(C_BLUE);
pub const CYAN = colorToFarbe(C_CYAN);
pub const GREEN = colorToFarbe(C_GREEN);
pub const PURPLE = colorToFarbe(C_PURPLE);
pub const RED = colorToFarbe(C_RED);
pub const YELLOW = colorToFarbe(C_YELLOW);

pub const DIM = ComptimeFarbe.init().dim();
pub const UNDERLINED = ComptimeFarbe.init().underlined();

pub fn randomColor() Color {
    var prng = std.rand.DefaultPrng.init(
        @intCast(std.time.milliTimestamp()),
    );
    var rand = prng.random();
    return .{
        .r = rand.int(u8),
        .g = rand.int(u8),
        .b = rand.int(u8),
    };
}
