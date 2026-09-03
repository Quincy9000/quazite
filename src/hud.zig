//! The face the framework's own words are written in: the readout in the corner, the
//! profile, the word after a save. Nothing by default, and then raylib's own font draws
//! them; a game that loads a face of its own puts it here, and everything the framework
//! writes changes with it rather than standing out in the old bitmap.

const world = @import("root.zig");
const rl = world.rl;

pub var face: ?rl.Font = null;

/// Letter spacing for a size: a little air, scaled with the size.
fn spacing(size: c_int) f32 {
    return @as(f32, @floatFromInt(size)) / 16;
}

pub fn drawText(text: [*c]const u8, x: c_int, y: c_int, size: c_int, color: rl.Color) void {
    const f = face orelse {
        rl.DrawText(text, x, y, size, color);
        return;
    };
    rl.DrawTextEx(f, text, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, @floatFromInt(size), spacing(size), color);
}

pub fn measureText(text: [*c]const u8, size: c_int) c_int {
    const f = face orelse return rl.MeasureText(text, size);
    return @intFromFloat(rl.MeasureTextEx(f, text, @floatFromInt(size), spacing(size)).x);
}
