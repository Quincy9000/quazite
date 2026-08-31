//! The devices, and nothing about what they are for. The keyboard, the mouse, the
//! pads, the touch screen: each read through a small set of questions, and a few
//! helpers for turning what they say into the shapes a game wants — a pair of keys as
//! an axis, a stick with its wobble taken out, a level turned into an edge. What any
//! of it *means* — which key jumps, which stick looks — is the game's to say, in the
//! game's own files. Nothing here is named for what it does; only for what it is.
//!
//! The game says it by name, at the bottom: `bind("jump", .{ .key = rl.KEY_SPACE })`
//! and `bind("jump", .{ .pad = ... })` once, then `isActionPressed("jump")` wherever
//! it is asked, without knowing or caring which device answered. Axes the same:
//! `bindAxis("move", ...)` for the keys and again for the stick, and `getAxis("move")`
//! is one vector whoever is pushing. The names are the game's; none are here.
//!
//! The device questions are stateless and answer about this frame; raylib keeps the
//! frame's state. The names have memory — what was held last frame — and `poll` has
//! to be called once, first thing, every frame for them to have it.

const std = @import("std");
const rl = @import("raylib.zig").c;

// ---- the keyboard ----

pub fn keyDown(key: c_int) bool {
    return rl.IsKeyDown(key);
}

/// Pressed this frame: not down last frame, down now.
pub fn keyPressed(key: c_int) bool {
    return rl.IsKeyPressed(key);
}

/// Pressed this frame, or held long enough that the system is repeating it: what a
/// text field or a menu that scrolls under a held key wants.
pub fn keyRepeated(key: c_int) bool {
    return rl.IsKeyPressed(key) or rl.IsKeyPressedRepeat(key);
}

pub fn keyReleased(key: c_int) bool {
    return rl.IsKeyReleased(key);
}

/// A pair of keys as an axis: minus one with the first held, one with the second,
/// nought with neither or both.
pub fn keyPair(negative: c_int, positive: c_int) f32 {
    return pair(rl.IsKeyDown(negative), rl.IsKeyDown(positive));
}

/// Four keys as a stick: x from the first pair, y from the second, each minus one to
/// one — so WASD is `keyStick(KEY_A, KEY_D, KEY_S, KEY_W)`, with y up.
pub fn keyStick(left: c_int, right: c_int, down: c_int, up: c_int) rl.Vector2 {
    return .{ .x = keyPair(left, right), .y = keyPair(down, up) };
}

/// The next key in the queue of those pressed this frame, or null when it is empty.
/// Ask again for the next.
pub fn keyTyped() ?c_int {
    const key = rl.GetKeyPressed();
    return if (key == 0) null else key;
}

/// The next character typed this frame, as unicode, or null when there are no more.
/// The keyboard's layout and shift are already applied: this is what a text field
/// reads.
pub fn charTyped() ?u21 {
    const char = rl.GetCharPressed();
    return if (char == 0) null else @intCast(char);
}

// ---- the mouse ----

pub fn mouseDown(button: c_int) bool {
    return rl.IsMouseButtonDown(button);
}

pub fn mousePressed(button: c_int) bool {
    return rl.IsMouseButtonPressed(button);
}

pub fn mouseReleased(button: c_int) bool {
    return rl.IsMouseButtonReleased(button);
}

/// Where the pointer is on the screen, in pixels from the top left.
pub fn mouse() rl.Vector2 {
    return rl.GetMousePosition();
}

/// How far the mouse moved this frame. With the mouse grabbed this is the only thing
/// it says, and it keeps saying it however far it goes.
pub fn mouseDelta() rl.Vector2 {
    return rl.GetMouseDelta();
}

pub fn mouseMoved() bool {
    const moved = rl.GetMouseDelta();
    return moved.x != 0 or moved.y != 0;
}

/// Whether the pointer is inside a rectangle on the screen.
pub fn mouseOver(box: rl.Rectangle) bool {
    return rl.CheckCollisionPointRec(rl.GetMousePosition(), box);
}

/// A button pressed this frame with the pointer inside a rectangle: a click on a thing.
pub fn clicked(box: rl.Rectangle, button: c_int) bool {
    return rl.IsMouseButtonPressed(button) and mouseOver(box);
}

/// The wheel's turn this frame: up is positive.
pub fn wheel() f32 {
    return rl.GetMouseWheelMove();
}

/// Both of the wheel's turns, for a wheel that tilts sideways too.
pub fn wheelBoth() rl.Vector2 {
    return rl.GetMouseWheelMoveV();
}

/// Hides the pointer and keeps it in the window: the mouse becomes a pure movement,
/// read through `mouseDelta`. What a first-person look wants.
pub fn grabMouse() void {
    rl.DisableCursor();
}

/// The pointer back, free to leave the window.
pub fn freeMouse() void {
    rl.EnableCursor();
}

pub fn mouseGrabbed() bool {
    return rl.IsCursorHidden();
}

pub fn mouseOnScreen() bool {
    return rl.IsCursorOnScreen();
}

// ---- the pads ----

/// How many pads raylib will look after at once.
pub const slots = 4;

/// One pad, by its slot. `pad()` finds the first plugged in; a game with more than
/// one player makes its own by slot.
pub const Pad = struct {
    slot: c_int,

    pub fn plugged(p: Pad) bool {
        return rl.IsGamepadAvailable(p.slot);
    }

    /// What the system calls it, or null when nothing is in the slot.
    pub fn name(p: Pad) ?[*:0]const u8 {
        if (!p.plugged()) return null;
        const text = rl.GetGamepadName(p.slot);
        return if (text == null) null else text;
    }

    pub fn down(p: Pad, button: c_int) bool {
        return rl.IsGamepadButtonDown(p.slot, button);
    }

    pub fn pressed(p: Pad, button: c_int) bool {
        return rl.IsGamepadButtonPressed(p.slot, button);
    }

    pub fn released(p: Pad, button: c_int) bool {
        return rl.IsGamepadButtonReleased(p.slot, button);
    }

    /// A pair of buttons as an axis, the way `keyPair` is.
    pub fn pair(p: Pad, negative: c_int, positive: c_int) f32 {
        return input_pair(p.down(negative), p.down(positive));
    }

    /// One axis, minus one to one, with the wobble about the middle taken out. Note
    /// raylib's sticks read down and right as positive.
    pub fn axis(p: Pad, which: c_int, zone: f32) f32 {
        return deaden(rl.GetGamepadAxisMovement(p.slot, which), zone);
    }

    /// A stick as one vector, its deadzone round rather than square so a diagonal
    /// push is not quieter than a straight one. y is flipped to read up as positive,
    /// the same way `keyStick` does.
    pub fn stick(p: Pad, x_axis: c_int, y_axis: c_int, zone: f32) rl.Vector2 {
        return deadenVector(.{
            .x = rl.GetGamepadAxisMovement(p.slot, x_axis),
            .y = -rl.GetGamepadAxisMovement(p.slot, y_axis),
        }, zone);
    }

    /// A trigger as a pull, nought at rest to one pulled home. Raylib reads a trigger
    /// minus one to one. Some pads read nought until first touched, which comes out
    /// as a half pull here until they are — a game that cares can wait for a full
    /// rest reading before trusting one.
    pub fn trigger(p: Pad, which: c_int) f32 {
        const raw = rl.GetGamepadAxisMovement(p.slot, which);
        return std.math.clamp((raw + 1) / 2, 0, 1);
    }

    /// Whether an axis is pushed past a line, on whichever side of nought the line
    /// is: a stick or trigger read as a button. Feed it to an `Edge` for a press.
    pub fn tilted(p: Pad, which: c_int, past: f32) bool {
        const value = rl.GetGamepadAxisMovement(p.slot, which);
        return if (past >= 0) value > past else value < past;
    }

    /// The motors, for a while: each nought to one.
    pub fn rumble(p: Pad, left: f32, right: f32, seconds: f32) void {
        rl.SetGamepadVibration(p.slot, left, right, seconds);
    }
};

/// The slot the game has chosen, if it has: `input.pad_slot = 1`. Otherwise the pad is
/// found by its name.
pub var pad_slot: ?c_int = null;

/// The pad in use, or null when there is none. The system offers everything with an
/// axis as a joystick — touchpads, keyboards' media wheels, a dongle — and a laptop's
/// touchpad is likely to be in slot 0 with a real controller behind it. So: the
/// first slot whose name says it is a controller; failing that the first that does
/// not say it is a touchpad, keyboard or mouse. Looked for afresh each call, so one
/// unplugged and another plugged in is followed without anyone noticing.
pub fn pad() ?Pad {
    if (pad_slot) |slot| {
        const chosen = Pad{ .slot = slot };
        return if (chosen.plugged()) chosen else null;
    }
    var fallback: ?Pad = null;
    for (0..slots) |slot| {
        const p = Pad{ .slot = @intCast(slot) };
        if (!p.plugged()) continue;
        switch (looks(std.mem.span(p.name() orelse continue))) {
            .pad => return p,
            .unknown => if (fallback == null) {
                fallback = p;
            },
            .not_a_pad => {},
        }
    }
    return fallback;
}

fn looks(name: []const u8) enum { pad, unknown, not_a_pad } {
    const pads = [_][]const u8{ "controller", "gamepad", "game pad", "joystick", "joypad", "xbox", "x-box", "playstation", "dualshock", "dualsense", "nintendo", "8bitdo", "stadia", "steam" };
    for (pads) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .pad;
    }
    const nots = [_][]const u8{ "touchpad", "trackpad", "keyboard", "mouse", "receiver", "tablet", "pen" };
    for (nots) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) != null) return .not_a_pad;
    }
    return .unknown;
}

pub fn padPlugged() bool {
    return pad() != null;
}

// The same questions of the first pad, for the common case of one player: each is
// the pad's own answer, or nothing with no pad plugged in.

pub fn padDown(button: c_int) bool {
    return if (pad()) |p| p.down(button) else false;
}

pub fn padPressed(button: c_int) bool {
    return if (pad()) |p| p.pressed(button) else false;
}

pub fn padReleased(button: c_int) bool {
    return if (pad()) |p| p.released(button) else false;
}

pub fn padPair(negative: c_int, positive: c_int) f32 {
    return if (pad()) |p| p.pair(negative, positive) else 0;
}

pub fn padAxis(which: c_int, zone: f32) f32 {
    return if (pad()) |p| p.axis(which, zone) else 0;
}

pub fn stick(x_axis: c_int, y_axis: c_int, zone: f32) rl.Vector2 {
    return if (pad()) |p| p.stick(x_axis, y_axis, zone) else .{ .x = 0, .y = 0 };
}

pub fn trigger(which: c_int) f32 {
    return if (pad()) |p| p.trigger(which) else 0;
}

pub fn tilted(which: c_int, past: f32) bool {
    return if (pad()) |p| p.tilted(which, past) else false;
}

/// The last pad button pressed, on any pad, or null when none was.
pub fn padButtonTyped() ?c_int {
    const button = rl.GetGamepadButtonPressed();
    return if (button == rl.GAMEPAD_BUTTON_UNKNOWN) null else button;
}

// ---- the touch screen ----

pub fn touches() usize {
    return @intCast(@max(rl.GetTouchPointCount(), 0));
}

/// Where a finger is, by its index among those down this frame.
pub fn touch(index: usize) rl.Vector2 {
    return rl.GetTouchPosition(@intCast(index));
}

// ---- shaping ----

/// Two levels as an axis: minus one for the first, one for the second, nought for
/// neither or both.
pub fn pair(negative: bool, positive: bool) f32 {
    return @as(f32, if (positive) 1 else 0) - @as(f32, if (negative) 1 else 0);
}

// `Pad.pair` shadows the name inside the struct; this is the same function by another.
const input_pair = pair;

/// Several readings of one axis — a key pair and a stick, say — added and held to
/// minus one to one, so two pushing together still read as one.
pub fn sum(readings: []const f32) f32 {
    var total: f32 = 0;
    for (readings) |reading| total += reading;
    return std.math.clamp(total, -1, 1);
}

/// The same for vectors: added, and held to a length of one.
pub fn sumVectors(readings: []const rl.Vector2) rl.Vector2 {
    var total = rl.Vector2{ .x = 0, .y = 0 };
    for (readings) |reading| total = rl.Vector2Add(total, reading);
    return if (rl.Vector2Length(total) > 1) rl.Vector2Normalize(total) else total;
}

/// A reading with the wobble about the middle taken out, and the rest scaled so a
/// full push still reads one.
pub fn deaden(value: f32, zone: f32) f32 {
    const size = @abs(value);
    if (size < zone) return 0;
    return std.math.sign(value) * (size - zone) / (1 - zone);
}

/// The same for a vector, by its length rather than each part: a round deadzone.
pub fn deadenVector(value: rl.Vector2, zone: f32) rl.Vector2 {
    const size = rl.Vector2Length(value);
    if (size < zone) return .{ .x = 0, .y = 0 };
    const scale = @min((size - zone) / (1 - zone), 1) / size;
    return rl.Vector2Scale(value, scale);
}

/// A press or a release made out of a level, for anything that only ever says whether
/// it is on: a stick past a line, a trigger past a pull, two keys together. The game
/// keeps one per thing and feeds it every frame:
///
///     var jump: input.Edge = .{};
///     if (jump.rose(input.tilted(rl.GAMEPAD_AXIS_RIGHT_TRIGGER, 0))) ...
pub const Edge = struct {
    was: bool = false,

    /// Whether the level came on this frame. Remembers it for next time.
    pub fn rose(edge: *Edge, now: bool) bool {
        defer edge.was = now;
        return now and !edge.was;
    }

    /// Whether the level went off this frame. Remembers it for next time.
    pub fn fell(edge: *Edge, now: bool) bool {
        defer edge.was = now;
        return !now and edge.was;
    }

    /// Both at once, for a thing that wants to know either.
    pub fn step(edge: *Edge, now: bool) struct { rose: bool, fell: bool } {
        defer edge.was = now;
        return .{ .rose = now and !edge.was, .fell = !now and edge.was };
    }
};

// ---- by name ----
//
// Actions are things done, on or off: a name, and every key, button and tilt that
// does it. Axes are things pushed: a name, and every set of keys, buttons and sticks
// that push it, read together as one vector, minus one to one each way. The game
// binds them once at the start — `bind` and `bindAxis` — and asks by name after.
// Nothing is bound until it does.

/// The most bindings, axis pushes and sequences there can be, each. Raise it if a
/// game runs out.
pub const max_bindings = 256;

/// The most keys one sequence can be.
pub const max_sequence = 4;

/// Seconds a half-finished sequence waits for its next key before it is forgotten.
pub var sequence_time: f32 = 1.2;

/// How far a stick reads before it counts, for every stick read by name.
pub var deadzone: f32 = 0.2;

/// One way of doing an action.
pub const Source = union(enum) {
    key: c_int,
    mouse: c_int,
    /// A button on the first pad plugged in.
    pad: c_int,
    /// A stick or trigger pushed past a line counts as a button: held while the axis
    /// reads beyond `past`, on whichever side of nought `past` is. A trigger reads
    /// minus one at rest and one pulled home, so `past = 0` is a half pull.
    tilt: struct { axis: c_int, past: f32 },
};

/// One way of pushing an axis. Every part is optional: a one-way axis binds only the
/// parts it has, and the rest read nought.
pub const Push = union(enum) {
    /// Keys: x from left and right, y from down and up. WASD is
    /// `.{ .left = KEY_A, .right = KEY_D, .down = KEY_S, .up = KEY_W }`.
    keys: struct { left: c_int = 0, right: c_int = 0, down: c_int = 0, up: c_int = 0 },
    /// The same on the pad's buttons: a D-pad, or a pair of bumpers as one line.
    pads: struct { left: c_int = 0, right: c_int = 0, down: c_int = 0, up: c_int = 0 },
    /// A stick, y flipped to read up as positive. Leave y out for a one-way axis.
    stick: struct { x: ?c_int = null, y: ?c_int = null },
    /// A pair of triggers as one line: the first pulls toward minus one, the second
    /// toward one. Leave one out for a pull that only goes one way.
    triggers: struct { negative: ?c_int = null, positive: ?c_int = null },
};

const Binding = struct {
    name: []const u8,
    source: Source,
    held: bool = false,
    was: bool = false,
};

const Pushing = struct {
    name: []const u8,
    push: Push,
};

/// A sequence: a name and the keys, in order, that do it.
const Sequence = struct {
    name: []const u8,
    keys: [max_sequence]c_int,
    len: u8,
};

var sequences: [max_bindings]Sequence = undefined;
var sequenced: usize = 0;
/// The keys pressed so far toward some sequence, and when the last of them was.
var partial: [max_sequence]c_int = undefined;
var partial_len: u8 = 0;
var partial_at: f64 = 0;
/// The sequences finished this poll: what `isActionPressed` answers for.
var fired: [8][]const u8 = undefined;
var fired_len: usize = 0;

var bindings: [max_bindings]Binding = undefined;
var bound: usize = 0;
var pushes: [max_bindings]Pushing = undefined;
var pushed: usize = 0;

/// Gives an action one more way of being done. The name is kept, not copied: hand it
/// a literal, or something that lives as long as the binding.
pub fn bind(name: []const u8, source: Source) void {
    if (bound == max_bindings) @panic("too many input bindings: raise input.max_bindings");
    bindings[bound] = .{ .name = name, .source = source };
    bound += 1;
}

/// Gives an axis one more way of being pushed.
pub fn bindAxis(name: []const u8, push: Push) void {
    if (pushed == max_bindings) @panic("too many input axes: raise input.max_bindings");
    pushes[pushed] = .{ .name = name, .push = push };
    pushed += 1;
}

/// Gives an action a run of keys that does it, in order: `bindSequence("grid.new",
/// &.{ rl.KEY_G, rl.KEY_N })` is G then N. A key that begins a sequence does not do
/// its own single-key action while the rest is awaited — the sequence has it — and a
/// run left half-finished is forgotten after `sequence_time`.
pub fn bindSequence(name: []const u8, keys: []const c_int) void {
    if (sequenced == max_bindings) @panic("too many input sequences: raise input.max_bindings");
    if (keys.len == 0 or keys.len > max_sequence) @panic("a sequence is one to max_sequence keys");
    var made = Sequence{ .name = name, .keys = undefined, .len = @intCast(keys.len) };
    @memcpy(made.keys[0..keys.len], keys);
    sequences[sequenced] = made;
    sequenced += 1;
}

/// The keys of a sequence pressed so far, for showing what is being waited on.
/// Empty when nothing is half-done.
pub fn pending() []const c_int {
    return partial[0..partial_len];
}

/// Takes every sequence of an action away.
pub fn unbindSequence(name: []const u8) void {
    var kept: usize = 0;
    for (sequences[0..sequenced]) |sequence| {
        if (std.mem.eql(u8, sequence.name, name)) continue;
        sequences[kept] = sequence;
        kept += 1;
    }
    sequenced = kept;
}

/// Takes every binding of an action away, for binding it afresh.
pub fn unbind(name: []const u8) void {
    var kept: usize = 0;
    for (bindings[0..bound]) |binding| {
        if (std.mem.eql(u8, binding.name, name)) continue;
        bindings[kept] = binding;
        kept += 1;
    }
    bound = kept;
}

/// Takes every push of an axis away, for binding it afresh.
pub fn unbindAxis(name: []const u8) void {
    var kept: usize = 0;
    for (pushes[0..pushed]) |pushing| {
        if (std.mem.eql(u8, pushing.name, name)) continue;
        pushes[kept] = pushing;
        kept += 1;
    }
    pushed = kept;
}

/// Every action and axis forgotten.
pub fn unbindAll() void {
    bound = 0;
    pushed = 0;
    sequenced = 0;
    partial_len = 0;
    fired_len = 0;
}

/// Reads every bound source once. Call it first thing every frame, before anything
/// asks by name: "pressed" is what changed since the last call.
pub fn poll() void {
    const p = pad();
    for (bindings[0..bound]) |*binding| {
        binding.was = binding.held;
        binding.held = live(binding.source, p);
    }
    pollSequences();
}

/// The sequences carried on: a key pressed this frame is added to the run, which
/// either finishes one, waits for more, or is forgotten.
fn pollSequences() void {
    fired_len = 0;
    if (sequenced == 0) return;
    const now = rl.GetTime();
    if (partial_len > 0 and now - partial_at > sequence_time) partial_len = 0;

    // The key that could come next: the first of every sequence, or the next of one
    // the run has begun. One at a time — two keys in a frame is two steps.
    var pressed_key: ?c_int = null;
    for (sequences[0..sequenced]) |sequence| {
        if (partial_len >= sequence.len or !begins(sequence)) continue;
        const key = sequence.keys[partial_len];
        if (rl.IsKeyPressed(key)) {
            pressed_key = key;
            break;
        }
    }
    const key = pressed_key orelse return;

    partial[partial_len] = key;
    partial_len += 1;
    partial_at = now;

    // Whatever the run now finishes, fired; and whether anything is still waiting.
    var waiting = false;
    for (sequences[0..sequenced]) |sequence| {
        if (!begins(sequence)) continue;
        if (sequence.len == partial_len) {
            if (fired_len < fired.len) {
                fired[fired_len] = sequence.name;
                fired_len += 1;
            }
        } else {
            waiting = true;
        }
    }
    if (!waiting or fired_len > 0) partial_len = 0;
}

/// Whether the run so far is the beginning of a sequence.
fn begins(sequence: Sequence) bool {
    if (partial_len > sequence.len) return false;
    for (partial[0..partial_len], sequence.keys[0..partial_len]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// Whether a key is the first of some sequence: then it is the sequence's, and its
/// own single-key action does not answer while the rest is awaited.
fn opensSequence(key: c_int) bool {
    for (sequences[0..sequenced]) |sequence| {
        if (sequence.keys[0] == key) return true;
    }
    return false;
}

fn live(source: Source, p: ?Pad) bool {
    return switch (source) {
        .key => |key| rl.IsKeyDown(key),
        .mouse => |button| rl.IsMouseButtonDown(button),
        .pad => |button| if (p) |on| on.down(button) else false,
        .tilt => |tilt| if (p) |on| on.tilted(tilt.axis, tilt.past) else false,
    };
}

/// Held this frame, by any of its sources.
pub fn isActionDown(name: []const u8) bool {
    for (bindings[0..bound]) |binding| {
        if (binding.held and std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

/// Held this frame by a source that was not held at the last poll.
pub fn isActionPressed(name: []const u8) bool {
    for (fired[0..fired_len]) |done| {
        if (std.mem.eql(u8, done, name)) return true;
    }
    for (bindings[0..bound]) |binding| {
        if (!binding.held or binding.was or !std.mem.eql(u8, binding.name, name)) continue;
        // A key that begins a sequence belongs to the sequence while one is awaited.
        switch (binding.source) {
            .key => |key| if (partial_len > 0 and opensSequence(key)) continue,
            else => {},
        }
        return true;
    }
    return false;
}

/// Let go this frame by a source that was held at the last poll.
pub fn isActionReleased(name: []const u8) bool {
    for (bindings[0..bound]) |binding| {
        if (!binding.held and binding.was and std.mem.eql(u8, binding.name, name)) return true;
    }
    return false;
}

/// How far an axis is pushed, as one vector: every push of it added, and held to a
/// length of one, so a key and a stick pushing together still read as one. x is
/// right and y is up, whichever device is pushing.
pub fn getAxis(name: []const u8) rl.Vector2 {
    const p = pad();
    var total = rl.Vector2{ .x = 0, .y = 0 };
    for (pushes[0..pushed]) |pushing| {
        if (!std.mem.eql(u8, pushing.name, name)) continue;
        total = rl.Vector2Add(total, read(pushing.push, p));
    }
    return if (rl.Vector2Length(total) > 1) rl.Vector2Normalize(total) else total;
}

fn read(push: Push, p: ?Pad) rl.Vector2 {
    const still = rl.Vector2{ .x = 0, .y = 0 };
    return switch (push) {
        .keys => |k| .{ .x = keyPair(k.left, k.right), .y = keyPair(k.down, k.up) },
        .pads => |k| if (p) |on| .{ .x = on.pair(k.left, k.right), .y = on.pair(k.down, k.up) } else still,
        .stick => |s| if (p) |on| stickOf(on, s.x, s.y) else still,
        .triggers => |t| if (p) |on| .{
            .x = (if (t.positive) |axis| on.trigger(axis) else 0) - (if (t.negative) |axis| on.trigger(axis) else 0),
            .y = 0,
        } else still,
    };
}

/// A stick with either part missing: the parts it has, deadened round when it has
/// both and flat when it has one.
fn stickOf(on: Pad, x: ?c_int, y: ?c_int) rl.Vector2 {
    if (x != null and y != null) return on.stick(x.?, y.?, deadzone);
    return .{
        .x = if (x) |axis| on.axis(axis, deadzone) else 0,
        .y = if (y) |axis| -on.axis(axis, deadzone) else 0,
    };
}

test "sequences: a run finishes one, a prefix holds its own key, and a stale run is dropped" {
    unbindAll();
    defer unbindAll();
    // No window here, so no key is ever down: what can be checked is the bookkeeping
    // — the runs bound, the prefix rule, and what a poll answers with none pressed.
    bindSequence("grid.new", &.{ 71, 78 }); // G N
    bindSequence("grid.wall", &.{ 71, 87 }); // G W
    bindSequence("save", &.{83}); // S
    bind("draw", .{ .key = 71 }); // G alone, which the sequences take while waiting

    try std.testing.expect(opensSequence(71));
    try std.testing.expect(!opensSequence(78));
    try std.testing.expectEqual(@as(usize, 0), pending().len);

    // A run part-way: both G sequences still begin with it; the single G is held back.
    partial[0] = 71;
    partial_len = 1;
    partial_at = 0;
    try std.testing.expectEqual(@as(usize, 1), pending().len);
    try std.testing.expect(begins(sequences[0]));
    try std.testing.expect(begins(sequences[1]));
    try std.testing.expect(!begins(sequences[2]));
    try std.testing.expect(!isActionPressed("draw"));

    // Whatever fired this poll answers pressed, once.
    fired[0] = "grid.new";
    fired_len = 1;
    try std.testing.expect(isActionPressed("grid.new"));
    try std.testing.expect(!isActionPressed("grid.wall"));
    fired_len = 0;
    try std.testing.expect(!isActionPressed("grid.new"));

    // A run older than the wait is forgotten at the next poll.
    partial_at = -1000;
    pollSequences();
    try std.testing.expectEqual(@as(usize, 0), pending().len);

    unbindSequence("grid.wall");
    try std.testing.expectEqual(@as(usize, 2), sequenced);
}
