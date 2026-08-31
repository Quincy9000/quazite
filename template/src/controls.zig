//! What the keys and the pad mean in this game: every action and axis, named here and
//! nowhere else. A module asks `input.isActionPressed("save")`, never for the key, so
//! moving a binding is a one-line change here and a controller does everything the
//! keyboard does because it is bound to the same names.
//!
//! The framework's own systems ask for these names: "move", "look", "climb", "zoom"
//! and "sprint" for the eye; "save", "load", "restart" and "profile" for the frame.
//! Leave one unbound and it simply never happens.

const world = @import("world");
const rl = world.rl;
const input = world.input;
const config = @import("main.zig").Spec.config;

pub fn bind() void {
    input.deadzone = config.deadzone;

    // ---- the world ----

    input.bindAxis("move", .{ .keys = .{ .left = rl.KEY_A, .right = rl.KEY_D, .down = rl.KEY_S, .up = rl.KEY_W } });
    input.bindAxis("move", .{ .stick = .{ .x = rl.GAMEPAD_AXIS_LEFT_X, .y = rl.GAMEPAD_AXIS_LEFT_Y } });
    input.bindAxis("look", .{ .keys = .{ .left = rl.KEY_LEFT, .right = rl.KEY_RIGHT, .down = rl.KEY_DOWN, .up = rl.KEY_UP } });
    input.bindAxis("look", .{ .stick = .{ .x = rl.GAMEPAD_AXIS_RIGHT_X, .y = rl.GAMEPAD_AXIS_RIGHT_Y } });
    input.bindAxis("climb", .{ .keys = .{ .down = rl.KEY_LEFT_CONTROL, .up = rl.KEY_SPACE } });
    input.bindAxis("climb", .{ .pads = .{ .down = rl.GAMEPAD_BUTTON_LEFT_TRIGGER_1, .up = rl.GAMEPAD_BUTTON_RIGHT_TRIGGER_1 } });
    // The flat eye's, on the same bumpers: a game is one or the other.
    input.bindAxis("zoom", .{ .keys = .{ .down = rl.KEY_MINUS, .up = rl.KEY_EQUAL } });
    input.bindAxis("zoom", .{ .pads = .{ .down = rl.GAMEPAD_BUTTON_LEFT_TRIGGER_1, .up = rl.GAMEPAD_BUTTON_RIGHT_TRIGGER_1 } });
    input.bind("sprint", .{ .key = rl.KEY_LEFT_SHIFT });
    input.bind("sprint", .{ .tilt = .{ .axis = rl.GAMEPAD_AXIS_RIGHT_TRIGGER, .past = 0 } });
    input.bind("use", .{ .mouse = rl.MOUSE_BUTTON_LEFT });
    input.bind("use", .{ .tilt = .{ .axis = rl.GAMEPAD_AXIS_LEFT_TRIGGER, .past = 0 } });

    // ---- the frame's own ----

    input.bind("save", .{ .key = rl.KEY_F5 });
    input.bind("load", .{ .key = rl.KEY_F9 });
    input.bind("restart", .{ .key = rl.KEY_R });
    input.bind("profile", .{ .key = rl.KEY_P });
}
