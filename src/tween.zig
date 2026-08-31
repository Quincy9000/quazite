//! Tweens: a value carried from here to there over so many seconds, along a curve.
//! A door swinging open, a coin popping up, a colour fading — anything that changes
//! smoothly is one of these, ticked by the clock's delta:
//!
//!     var rise: tween.Tween(f32) = .{ .from = 0, .to = 3, .seconds = 0.5, .curve = .back_out };
//!     ...
//!     coin.y = rise.tick(w.resource(Clock).delta);
//!     if (rise.done()) ...
//!
//! A tween is a value: keep it in a component or a resource, tick it where the thing
//! it drives is updated. The curves are the usual ones — `quad`, `cubic`, `quart`,
//! `sine`, `expo`, `circ`, `back`, `elastic`, `bounce`, each `_in`, `_out` and
//! `_in_out` — and `ease` gives any of them alone, for anything that has a nought to
//! one of its own. `mix` blends any tweenable type by a share, and `Timer` counts down.

const std = @import("std");
const rl = @import("raylib.zig").c;
const Clock = @import("clock.zig").Clock;

// ---- curves ----

pub const Ease = enum {
    linear,
    quad_in,
    quad_out,
    quad_in_out,
    cubic_in,
    cubic_out,
    cubic_in_out,
    quart_in,
    quart_out,
    quart_in_out,
    sine_in,
    sine_out,
    sine_in_out,
    expo_in,
    expo_out,
    expo_in_out,
    circ_in,
    circ_out,
    circ_in_out,
    /// Pulls back a little before going, or overshoots a little before settling.
    back_in,
    back_out,
    back_in_out,
    /// Springs past and wobbles into place.
    elastic_in,
    elastic_out,
    elastic_in_out,
    /// Drops and bounces to rest.
    bounce_in,
    bounce_out,
    bounce_in_out,
};

const Family = enum { quad, cubic, quart, sine, expo, circ, back, elastic, bounce };

/// Nought to one along a curve, for a nought to one of time. `back` and `elastic`
/// go a little outside nought to one on the way; that is what they are for.
pub fn ease(curve: Ease, t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return switch (curve) {
        .linear => x,
        .quad_in => in(.quad, x),
        .quad_out => out(.quad, x),
        .quad_in_out => inOut(.quad, x),
        .cubic_in => in(.cubic, x),
        .cubic_out => out(.cubic, x),
        .cubic_in_out => inOut(.cubic, x),
        .quart_in => in(.quart, x),
        .quart_out => out(.quart, x),
        .quart_in_out => inOut(.quart, x),
        .sine_in => in(.sine, x),
        .sine_out => out(.sine, x),
        .sine_in_out => inOut(.sine, x),
        .expo_in => in(.expo, x),
        .expo_out => out(.expo, x),
        .expo_in_out => inOut(.expo, x),
        .circ_in => in(.circ, x),
        .circ_out => out(.circ, x),
        .circ_in_out => inOut(.circ, x),
        .back_in => in(.back, x),
        .back_out => out(.back, x),
        .back_in_out => inOut(.back, x),
        .elastic_in => in(.elastic, x),
        .elastic_out => out(.elastic, x),
        .elastic_in_out => inOut(.elastic, x),
        .bounce_in => in(.bounce, x),
        .bounce_out => out(.bounce, x),
        .bounce_in_out => inOut(.bounce, x),
    };
}

/// Slow to start.
fn in(family: Family, t: f32) f32 {
    return switch (family) {
        .quad => t * t,
        .cubic => t * t * t,
        .quart => t * t * t * t,
        .sine => 1 - @cos(t * std.math.pi / 2),
        .expo => if (t == 0) 0 else std.math.pow(f32, 2, 10 * t - 10),
        .circ => 1 - @sqrt(1 - t * t),
        .back => blk: {
            const c1: f32 = 1.70158;
            const c3: f32 = c1 + 1;
            break :blk c3 * t * t * t - c1 * t * t;
        },
        .elastic => blk: {
            if (t == 0) break :blk 0;
            if (t == 1) break :blk 1;
            const c4: f32 = std.math.tau / 3.0;
            break :blk -std.math.pow(f32, 2, 10 * t - 10) * @sin((t * 10 - 10.75) * c4);
        },
        .bounce => 1 - bounceOut(1 - t),
    };
}

/// Slow to stop: the start's curve, turned round.
fn out(family: Family, t: f32) f32 {
    return 1 - in(family, 1 - t);
}

/// Slow both ends: the start's curve to the middle, the stop's from it.
fn inOut(family: Family, t: f32) f32 {
    return if (t < 0.5) in(family, 2 * t) / 2 else 1 - in(family, 2 - 2 * t) / 2;
}

fn bounceOut(t: f32) f32 {
    const n1: f32 = 7.5625;
    const d1: f32 = 2.75;
    if (t < 1 / d1) return n1 * t * t;
    if (t < 2 / d1) {
        const u = t - 1.5 / d1;
        return n1 * u * u + 0.75;
    }
    if (t < 2.5 / d1) {
        const u = t - 2.25 / d1;
        return n1 * u * u + 0.9375;
    }
    const u = t - 2.625 / d1;
    return n1 * u * u + 0.984375;
}

// ---- blending ----

/// From one value to another by a share, nought to one: numbers, vectors, colours,
/// and rotations, which go the short way round.
pub fn mix(comptime T: type, from: T, to: T, share: f32) T {
    return switch (T) {
        f32 => from + (to - from) * share,
        rl.Vector2 => rl.Vector2Lerp(from, to, share),
        rl.Vector3 => rl.Vector3Lerp(from, to, share),
        rl.Color => rl.ColorLerp(from, to, share),
        rl.Quaternion => rl.QuaternionSlerp(from, to, share),
        else => @compileError("no way to tween a " ++ @typeName(T)),
    };
}

/// One value along a curve, for anything that keeps its own nought to one.
pub fn along(comptime T: type, from: T, to: T, curve: Ease, t: f32) T {
    return mix(T, from, to, ease(curve, t));
}

// ---- the tween ----

pub const Loop = enum {
    /// There, and stays: `done` once it arrives.
    once,
    /// There, and from the start again, for ever.
    repeat,
    /// There and back, for ever.
    yoyo,
};

pub fn Tween(comptime T: type) type {
    return struct {
        from: T,
        to: T,
        seconds: f32,
        curve: Ease = .linear,
        /// Seconds to wait at `from` before setting off.
        delay: f32 = 0,
        loop: Loop = .once,
        /// Seconds ticked so far, the delay included.
        elapsed: f32 = 0,

        const Self = @This();

        /// Time passes; where the value is now.
        pub fn tick(tw: *Self, delta: f32) T {
            tw.elapsed += delta;
            return tw.value();
        }

        pub fn value(tw: *const Self) T {
            return mix(T, tw.from, tw.to, ease(tw.curve, tw.progress()));
        }

        /// How far along, nought to one, before the curve: nought through the delay,
        /// wrapping or turning back as the loop says.
        pub fn progress(tw: *const Self) f32 {
            if (tw.seconds <= 0) return 1;
            const t = (tw.elapsed - tw.delay) / tw.seconds;
            if (t <= 0) return 0;
            return switch (tw.loop) {
                .once => @min(t, 1),
                .repeat => t - @floor(t),
                .yoyo => blk: {
                    const lap = t - 2 * @floor(t / 2);
                    break :blk if (lap <= 1) lap else 2 - lap;
                },
            };
        }

        /// Arrived, and staying: only a `once` tween is ever done.
        pub fn done(tw: *const Self) bool {
            return tw.loop == .once and tw.elapsed >= tw.delay + tw.seconds;
        }

        /// Back to the start, delay and all.
        pub fn restart(tw: *Self) void {
            tw.elapsed = 0;
        }

        /// Turned round where it is: heads back to where it came from, at the same
        /// pace, from the value it has now.
        pub fn reverse(tw: *Self) void {
            const at = tw.progress();
            std.mem.swap(T, &tw.from, &tw.to);
            tw.elapsed = tw.delay + tw.seconds * (1 - at);
        }

        /// Aimed somewhere new from wherever it is now, starting over on the clock.
        pub fn retarget(tw: *Self, to: T) void {
            tw.from = tw.value();
            tw.to = to;
            tw.delay = 0;
            tw.elapsed = 0;
        }
    };
}

// ---- the timer ----

/// So many seconds, then it fires — once, or again every lap.
pub const Timer = struct {
    seconds: f32,
    repeat: bool = false,
    elapsed: f32 = 0,
    fired: bool = false,

    /// Time passes; whether it ran out this tick.
    pub fn tick(timer: *Timer, delta: f32) bool {
        if (timer.fired and !timer.repeat) return false;
        timer.elapsed += delta;
        if (timer.elapsed < timer.seconds) return false;
        if (timer.repeat) {
            timer.elapsed -= timer.seconds;
        } else {
            timer.elapsed = timer.seconds;
            timer.fired = true;
        }
        return true;
    }

    /// How far through the lap, nought to one.
    pub fn progress(timer: *const Timer) f32 {
        if (timer.seconds <= 0) return 1;
        return std.math.clamp(timer.elapsed / timer.seconds, 0, 1);
    }

    pub fn done(timer: *const Timer) bool {
        return timer.fired;
    }

    pub fn restart(timer: *Timer) void {
        timer.elapsed = 0;
        timer.fired = false;
    }
};

// ---- the resource: sequences, chained and side by side ----
//
// Godot's tweens, near enough. `Tweens` hands out a `Sequence` by handle; a sequence
// is steps one after another, each step a set of tweeners running together:
//
//     const ts = w.resource(tween.Tweens);
//     const seq = ts.get(try ts.create()).?;
//     _ = try seq.tween(f32, &door.angle, 90, 0.5, .{ .curve = .quad_out });   // step 1
//     _ = try seq.parallel().tween(rl.Color, &door.tint, rl.GREEN, 0.5, .{});  // joins step 1
//     _ = try seq.wait(0.2);                                                   // step 2
//     _ = try seq.call(&door, Door.opened);                                    // step 3
//
// Ticked by the `tweens` system out of the clock's delta; a finished sequence is let
// go of and its handle is dead. A target is a pointer, which has to hold still for
// as long as the tween runs — a resource, a global, a field of something on the heap.
// A component in the entity table moves when entities are added or removed: for one
// of those use `tweenBy`, a setter that finds the entity by id each time.

pub const Handle = struct {
    index: u32,
    generation: u32,

    pub const none: Handle = .{ .index = std.math.maxInt(u32), .generation = 0 };
};

pub const Tweens = struct {
    gpa: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty,

    const Slot = struct {
        generation: u32 = 0,
        seq: ?*Sequence = null,
    };

    /// A new, empty sequence: build it up through `get`. It starts running at once,
    /// which for an empty sequence is finishing at the next tick — so add its steps
    /// before the frame is out.
    pub fn create(ts: *Tweens) !Handle {
        const seq = try ts.gpa.create(Sequence);
        errdefer ts.gpa.destroy(seq);
        seq.* = .{ .gpa = ts.gpa };
        const index: u32 = ts.free.pop() orelse blk: {
            try ts.slots.append(ts.gpa, .{});
            try ts.free.ensureTotalCapacity(ts.gpa, ts.slots.items.len);
            break :blk @intCast(ts.slots.items.len - 1);
        };
        ts.slots.items[index].seq = seq;
        return .{ .index = index, .generation = ts.slots.items[index].generation };
    }

    /// The sequence a handle names, or null once it has finished or been killed.
    /// Good until the next tick: take it, use it, let it go.
    pub fn get(ts: *Tweens, handle: Handle) ?*Sequence {
        if (handle.index >= ts.slots.items.len) return null;
        const slot = ts.slots.items[handle.index];
        if (slot.generation != handle.generation) return null;
        return slot.seq;
    }

    pub fn alive(ts: *Tweens, handle: Handle) bool {
        return ts.get(handle) != null;
    }

    /// Stops a sequence where it is and lets it go. Whether there was one.
    pub fn kill(ts: *Tweens, handle: Handle) bool {
        _ = ts.get(handle) orelse return false;
        ts.release(handle.index);
        return true;
    }

    pub fn killAll(ts: *Tweens) void {
        for (ts.slots.items, 0..) |slot, i| {
            if (slot.seq != null) ts.release(@intCast(i));
        }
    }

    pub fn running(ts: *const Tweens) usize {
        var count: usize = 0;
        for (ts.slots.items) |slot| {
            if (slot.seq != null) count += 1;
        }
        return count;
    }

    /// Every sequence carried on by so many seconds; the ones that finish, let go of.
    pub fn tick(ts: *Tweens, delta: f32) void {
        // By index, since a call may create a sequence mid-tick and move the list.
        var i: usize = 0;
        while (i < ts.slots.items.len) : (i += 1) {
            const seq = ts.slots.items[i].seq orelse continue;
            seq.advance(delta);
            if (seq.finished) ts.release(@intCast(i));
        }
    }

    fn release(ts: *Tweens, index: u32) void {
        const slot = &ts.slots.items[index];
        if (slot.seq) |seq| {
            seq.deinit();
            ts.gpa.destroy(seq);
        }
        slot.seq = null;
        slot.generation +%= 1;
        ts.free.appendAssumeCapacity(index);
    }

    pub fn deinit(ts: *Tweens) void {
        ts.killAll();
        ts.slots.deinit(ts.gpa);
        ts.free.deinit(ts.gpa);
        ts.slots = .empty;
        ts.free = .empty;
    }
};

/// How one tweener goes: its curve, a wait before it starts, and where from — the
/// target's value as it stands when the tweener begins, unless one is given.
pub fn How(comptime T: type) type {
    return struct {
        curve: Ease = .linear,
        delay: f32 = 0,
        from: ?T = null,
    };
}

pub const Sequence = struct {
    gpa: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,
    /// The step running now.
    at: usize = 0,
    /// Laps still to run after this one; null is for ever.
    laps: ?u32 = 0,
    speed: f32 = 1,
    paused: bool = false,
    finished: bool = false,
    /// Whether the next tweener joins the current step rather than starting one.
    join: bool = false,

    // ---- building: every call hands the sequence back, for the next ----

    /// Carries what a pointer points at to a value over so many seconds, as the next
    /// step — or alongside the current one, after `parallel`.
    pub fn tween(seq: *Sequence, comptime T: type, target: *T, to: T, seconds: f32, how: How(T)) !*Sequence {
        try seq.add(tweener(T, .{ .ptr = target }, how.from, to, seconds, how.curve, how.delay));
        return seq;
    }

    /// The same through a setter, for anything that cannot be pointed at safely: the
    /// value is handed to `apply` with the context each tick. `from` has to be given,
    /// since there is nothing to read.
    pub fn tweenBy(seq: *Sequence, comptime T: type, context: ?*anyopaque, apply: *const fn (?*anyopaque, T) void, from: T, to: T, seconds: f32, how: How(T)) !*Sequence {
        try seq.add(tweener(T, .{ .set = .{ .context = context, .apply = apply } }, from, to, seconds, how.curve, how.delay));
        return seq;
    }

    /// Nothing, for so many seconds.
    pub fn wait(seq: *Sequence, seconds: f32) !*Sequence {
        try seq.add(.{ .wait = .{ .seconds = seconds } });
        return seq;
    }

    /// A function run once, when its step is reached.
    pub fn call(seq: *Sequence, context: ?*anyopaque, run: *const fn (?*anyopaque) void) !*Sequence {
        try seq.add(.{ .call = .{ .context = context, .run = run } });
        return seq;
    }

    /// The next tweener added runs alongside the last one, not after it.
    pub fn parallel(seq: *Sequence) *Sequence {
        seq.join = true;
        return seq;
    }

    /// The whole sequence again this many more times; null for ever.
    pub fn repeat(seq: *Sequence, laps: ?u32) *Sequence {
        seq.laps = laps;
        return seq;
    }

    /// How fast time runs for this sequence: two is twice as fast.
    pub fn setSpeed(seq: *Sequence, speed: f32) *Sequence {
        seq.speed = speed;
        return seq;
    }

    pub fn pause(seq: *Sequence) void {
        seq.paused = true;
    }

    pub fn play(seq: *Sequence) void {
        seq.paused = false;
    }

    /// Over where it stands: let go of at the next tick.
    pub fn stop(seq: *Sequence) void {
        seq.finished = true;
    }

    /// The step being run, and how many there are.
    pub fn step(seq: *const Sequence) usize {
        return seq.at;
    }

    pub fn stepCount(seq: *const Sequence) usize {
        return seq.steps.items.len;
    }

    fn add(seq: *Sequence, tw: Tweener) !void {
        if (seq.join and seq.steps.items.len > 0) {
            try seq.steps.items[seq.steps.items.len - 1].tweeners.append(seq.gpa, tw);
        } else {
            var made: Step = .{};
            try made.tweeners.append(seq.gpa, tw);
            errdefer made.tweeners.deinit(seq.gpa);
            try seq.steps.append(seq.gpa, made);
        }
        seq.join = false;
    }

    // ---- running ----

    fn advance(seq: *Sequence, seconds: f32) void {
        if (seq.finished or seq.paused) return;
        if (seq.steps.items.len == 0) {
            seq.finished = true;
            return;
        }
        var left = seconds * seq.speed;
        // A step that ends mid-tick hands what is left of the tick to the next; a
        // run of instant steps is bounded, so a loop of nothing cannot spin for ever.
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            const current = &seq.steps.items[seq.at];
            current.elapsed += left;
            current.run();
            const length = current.duration();
            if (current.elapsed < length) return;
            left = current.elapsed - length;

            seq.at += 1;
            if (seq.at == seq.steps.items.len) {
                if (seq.laps) |laps| {
                    if (laps == 0) {
                        seq.finished = true;
                        return;
                    }
                    seq.laps = laps - 1;
                }
                seq.at = 0;
                for (seq.steps.items) |*s| s.reset();
            }
            // Nothing left of the tick: the next step begins with the next one.
            if (left <= 0) return;
        }
    }

    fn deinit(seq: *Sequence) void {
        for (seq.steps.items) |*s| s.tweeners.deinit(seq.gpa);
        seq.steps.deinit(seq.gpa);
    }
};

const Step = struct {
    tweeners: std.ArrayList(Tweener) = .empty,
    elapsed: f32 = 0,

    /// As long as the longest tweener in it, its delay included.
    fn duration(s: *const Step) f32 {
        var longest: f32 = 0;
        for (s.tweeners.items) |tw| longest = @max(longest, tw.duration());
        return longest;
    }

    fn run(s: *Step) void {
        for (s.tweeners.items) |*tw| tw.apply(s.elapsed);
    }

    fn reset(s: *Step) void {
        s.elapsed = 0;
        for (s.tweeners.items) |*tw| tw.reset();
    }
};

fn Target(comptime T: type) type {
    return union(enum) {
        ptr: *T,
        set: struct { context: ?*anyopaque, apply: *const fn (?*anyopaque, T) void },

        fn read(target: @This()) ?T {
            return switch (target) {
                .ptr => |p| p.*,
                .set => null,
            };
        }

        fn write(target: @This(), value: T) void {
            switch (target) {
                .ptr => |p| p.* = value,
                .set => |s| s.apply(s.context, value),
            }
        }
    };
}

fn Lerp(comptime T: type) type {
    return struct {
        target: Target(T),
        from: ?T,
        to: T,
        seconds: f32,
        curve: Ease,
        delay: f32,
        /// Where it set off from, taken as it began.
        start: ?T = null,

        fn apply(l: *@This(), elapsed: f32) void {
            const local = elapsed - l.delay;
            if (local < 0) return;
            if (l.start == null) l.start = l.from orelse l.target.read() orelse l.to;
            const t: f32 = if (l.seconds <= 0) 1 else @min(local / l.seconds, 1);
            l.target.write(mix(T, l.start.?, l.to, ease(l.curve, t)));
        }
    };
}

const Tweener = union(enum) {
    number: Lerp(f32),
    vec2: Lerp(rl.Vector2),
    vec3: Lerp(rl.Vector3),
    color: Lerp(rl.Color),
    quat: Lerp(rl.Quaternion),
    wait: struct { seconds: f32 },
    call: struct { context: ?*anyopaque, run: *const fn (?*anyopaque) void, ran: bool = false },

    fn apply(tw: *Tweener, elapsed: f32) void {
        switch (tw.*) {
            inline .number, .vec2, .vec3, .color, .quat => |*l| l.apply(elapsed),
            .wait => {},
            .call => |*c| if (!c.ran) {
                c.ran = true;
                c.run(c.context);
            },
        }
    }

    fn duration(tw: Tweener) f32 {
        return switch (tw) {
            inline .number, .vec2, .vec3, .color, .quat => |l| l.delay + l.seconds,
            .wait => |w| w.seconds,
            .call => 0,
        };
    }

    fn reset(tw: *Tweener) void {
        switch (tw.*) {
            inline .number, .vec2, .vec3, .color, .quat => |*l| l.start = null,
            .wait => {},
            .call => |*c| c.ran = false,
        }
    }
};

fn tweener(comptime T: type, target: Target(T), from: ?T, to: T, seconds: f32, curve: Ease, delay: f32) Tweener {
    const l = Lerp(T){ .target = target, .from = from, .to = to, .seconds = seconds, .curve = curve, .delay = delay };
    return switch (T) {
        f32 => .{ .number = l },
        rl.Vector2 => .{ .vec2 = l },
        rl.Vector3 => .{ .vec3 = l },
        rl.Color => .{ .color = l },
        rl.Quaternion => .{ .quat = l },
        else => @compileError("no way to tween a " ++ @typeName(T)),
    };
}

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const W = core.W;

        fn tickAll(w: *W) void {
            w.resource(Tweens).tick(w.resource(Clock).delta);
        }

        fn close(w: *W) void {
            w.resource(Tweens).deinit();
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Tweens{ .gpa = allocator });
            // After the clock, whose step it takes; before anything that reads a tweened value.
            try w.addSystem(allocator, .{ .name = "tweens", .onUpdate = tickAll, .onCleanup = close });
        }
    };
}

// ---- tests: zig build test ----

test "every curve starts at nought and ends at one" {
    inline for (std.meta.fields(Ease)) |field| {
        const curve: Ease = @enumFromInt(field.value);
        try std.testing.expectApproxEqAbs(@as(f32, 0), ease(curve, 0), 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1), ease(curve, 1), 1e-5);
        // In-out curves pass through the middle at the middle.
        if (std.mem.endsWith(u8, field.name, "_in_out")) try std.testing.expectApproxEqAbs(@as(f32, 0.5), ease(curve, 0.5), 1e-5);
    }
    try std.testing.expect(ease(.quad_in, 0.5) < 0.5);
    try std.testing.expect(ease(.quad_out, 0.5) > 0.5);
    try std.testing.expect(ease(.back_in, 0.2) < 0);
    try std.testing.expect(ease(.elastic_out, 0.4) > 1);
}

test "a tween goes there, waits first, loops or turns back as asked" {
    var t: Tween(f32) = .{ .from = 10, .to = 20, .seconds = 2 };
    try std.testing.expectEqual(@as(f32, 10), t.value());
    try std.testing.expectEqual(@as(f32, 15), t.tick(1));
    try std.testing.expect(!t.done());
    try std.testing.expectEqual(@as(f32, 20), t.tick(5));
    try std.testing.expect(t.done());

    var late: Tween(f32) = .{ .from = 0, .to = 1, .seconds = 1, .delay = 1 };
    try std.testing.expectEqual(@as(f32, 0), late.tick(0.5));
    try std.testing.expectEqual(@as(f32, 0.5), late.tick(1));

    var lap: Tween(f32) = .{ .from = 0, .to = 1, .seconds = 1, .loop = .repeat };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), lap.tick(2.25), 1e-5);
    try std.testing.expect(!lap.done());

    var back: Tween(f32) = .{ .from = 0, .to = 1, .seconds = 1, .loop = .yoyo };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), back.tick(1.5), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), back.tick(0.5), 1e-5);

    var turned: Tween(f32) = .{ .from = 0, .to = 10, .seconds = 1 };
    _ = turned.tick(0.3);
    turned.reverse();
    try std.testing.expectApproxEqAbs(@as(f32, 3), turned.value(), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), turned.tick(0.3), 1e-4);

    var v: Tween(rl.Vector3) = .{ .from = .{ .x = 0, .y = 0, .z = 0 }, .to = .{ .x = 2, .y = 4, .z = 6 }, .seconds = 1, .curve = .sine_in_out };
    const mid = v.tick(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), mid.y, 1e-5);
}

test "a timer fires once, or every lap" {
    var once: Timer = .{ .seconds = 1 };
    try std.testing.expect(!once.tick(0.6));
    try std.testing.expect(once.tick(0.6));
    try std.testing.expect(!once.tick(5));
    try std.testing.expect(once.done());

    var lap: Timer = .{ .seconds = 1, .repeat = true };
    try std.testing.expect(lap.tick(1.5));
    try std.testing.expect(!lap.tick(0.2));
    try std.testing.expect(lap.tick(0.4));
}

fn bump(context: ?*anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

test "a sequence runs its steps in turn, side by side when asked, waits, calls, and ends" {
    var ts = Tweens{ .gpa = std.testing.allocator };
    defer ts.deinit();
    var x: f32 = 3;
    var y: f32 = 0;
    var count: u32 = 0;

    const handle = try ts.create();
    const seq = ts.get(handle).?;
    _ = try seq.tween(f32, &x, 10, 1, .{}); // step 1: from where x stands, over a second
    _ = try seq.parallel().tween(f32, &y, 5, 2, .{}); // joins step 1: the step lasts two
    _ = try seq.wait(1); // step 2
    _ = try seq.call(&count, bump); // step 3, instant
    _ = try seq.tween(f32, &x, 0, 1, .{ .curve = .quad_out }); // step 4
    try std.testing.expectEqual(@as(usize, 4), seq.stepCount());

    ts.tick(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.5), x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), y, 1e-5);
    ts.tick(1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 5), y, 1e-5);
    try std.testing.expectEqual(@as(usize, 1), seq.step());
    // Half a second into the wait, then a second: the wait ends, the call fires, and
    // the half second left over goes into the last step.
    ts.tick(0.5);
    try std.testing.expectEqual(@as(u32, 0), count);
    ts.tick(1);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), x, 1e-4);
    ts.tick(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), x, 1e-5);
    // Finished, let go of: the handle is dead.
    try std.testing.expect(!ts.alive(handle));
    try std.testing.expectEqual(@as(usize, 0), ts.running());
    try std.testing.expect(!ts.kill(handle));
}

test "a sequence repeats, can be sped up, and can be killed" {
    var ts = Tweens{ .gpa = std.testing.allocator };
    defer ts.deinit();
    var count: u32 = 0;
    var v: f32 = 0;

    const twice = try ts.create();
    _ = try ts.get(twice).?.call(&count, bump);
    _ = try ts.get(twice).?.tween(f32, &v, 1, 1, .{});
    _ = ts.get(twice).?.repeat(1).setSpeed(2);
    ts.tick(0.5); // a whole lap at double speed: the call, then the tween to one
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectApproxEqAbs(@as(f32, 1), v, 1e-5);
    ts.tick(0.5); // the second lap: the call again, the tween from one to one
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(!ts.alive(twice));

    const forever = try ts.create();
    _ = ts.get(forever).?.repeat(null);
    _ = try ts.get(forever).?.tween(f32, &v, 0, 1, .{});
    ts.tick(10);
    try std.testing.expect(ts.alive(forever));
    try std.testing.expect(ts.kill(forever));
    try std.testing.expect(!ts.alive(forever));

    // A setter target, for what cannot be pointed at.
    const set = struct {
        fn apply(context: ?*anyopaque, value: f32) void {
            const into: *f32 = @ptrCast(@alignCast(context.?));
            into.* = value * 2;
        }
    };
    const by = try ts.create();
    _ = try ts.get(by).?.tweenBy(f32, &v, set.apply, 0, 10, 1, .{});
    ts.tick(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), v, 1e-5);
}
